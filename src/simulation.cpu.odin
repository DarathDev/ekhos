package ekhos

import "base:intrinsics"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:simd"
import "core:slice"
import "core:time"
import "import:pffft"
import utility "ekhos:utility"

assert :: utility.assert

cpuSimulator :: struct {
	info:   cpuSimulationInfo,
	timing: CpuTiming,
}

cpuSimulationInfo :: struct {
	apertureSampleCount: u32,
	scattererBatchSize:  u32,
}

CpuTiming :: struct {
	planning: time.Duration,
	simulation: time.Duration,
	stages:   CpuStageTiming,
}

create_cpu_simulator :: proc() -> (simulator: cpuSimulator, ok := true) { return }
destroy_cpu_simulator :: proc(simulator: ^cpuSimulator) { return }

plan_cpu_simulation :: proc(simulator: ^cpuSimulator, settings: ^SimulationSettings) -> (ok := true) { return }

SCATTER_BATCH_SIZE :: 256
DATALINE_BATCH_SIZE :: 1024
PROGRESS_LOG_DELAY_THRESHOLD :: 20.0 * time.Second
PROGRESS_LOG_INTERVAL :: 20.0 * time.Second
CPU_STAGE_TIMING :: bool(#config(CPU_STAGE_TIMING, false))

CpuStageTiming :: struct {
	allocation:       time.Duration,
	elementResponses: time.Duration,
	transmitCoalesce: time.Duration,
	receiveCoalesce:  time.Duration,
	convolution:      time.Duration,
	temporal:         time.Duration,
}

cpu_stage_timing_add :: proc(total: ^time.Duration, stopwatch: ^time.Stopwatch) {
	time.stopwatch_stop(stopwatch)
	total^ += time.stopwatch_duration(stopwatch^)
	stopwatch^ = {}
}

log_cpu_timing :: proc(timing: CpuTiming, label: string, loc := #caller_location) {
	when CPU_STAGE_TIMING {
		log.infof("%s planning stage: %v", label, timing.planning, location = loc)
		log.infof(`
%s CPU stage timing table:
stage                         total                 percent
allocation                    %16v                %.1f%%
element responses             %16v                %.1f%%
transmit coalescing           %16v                %.1f%%
receive coalescing            %16v                %.1f%%
convolution                   %16v                %.1f%%
temporal response             %16v                %.1f%%
total                         %16v                100.0%%`,
			label,
			timing.stages.allocation, timing.simulation > 0 ? 100 * f64(timing.stages.allocation) / f64(timing.simulation) : 0,
			timing.stages.elementResponses, timing.simulation > 0 ? 100 * f64(timing.stages.elementResponses) / f64(timing.simulation) : 0,
			timing.stages.transmitCoalesce, timing.simulation > 0 ? 100 * f64(timing.stages.transmitCoalesce) / f64(timing.simulation) : 0,
			timing.stages.receiveCoalesce, timing.simulation > 0 ? 100 * f64(timing.stages.receiveCoalesce) / f64(timing.simulation) : 0,
			timing.stages.convolution, timing.simulation > 0 ? 100 * f64(timing.stages.convolution) / f64(timing.simulation) : 0,
			timing.stages.temporal, timing.simulation > 0 ? 100 * f64(timing.stages.temporal) / f64(timing.simulation) : 0,
			timing.simulation,
			location = loc,
		)
	}
}

simulate_cpu :: proc(
	simulator: ^cpuSimulator,
	settings: SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
	impulses: []TransducerImpulse,
	excitations: []Excitation,
) -> (
	data: []f32,
	ok := true,
) {
	utility.prof_scoped(#procedure)
	totalStopwatch: time.Stopwatch
	time.stopwatch_start(&totalStopwatch)
	timing: CpuStageTiming

	// TODO: Add multi-core support

	cumulative: bool = auto_cast settings.cumulative
	samplingFrequency := settings.samplingFrequency
	startTime := settings.startTime
	speedOfSound := settings.speedOfSound

	sampleCount := settings.sampleCount
	transmissionCount: i32 = auto_cast len(transmissions)
	receiveChannelCount: i32 = auto_cast len(receiveChannels)
	scatterCount: i32 = auto_cast len(scatters)

	if transmissionCount == 0 || receiveChannelCount == 0 || scatterCount == 0 {
		return
	}

	totalDatalineScatters := i64(scatterCount) * i64(transmissionCount) * i64(receiveChannelCount)
	completedDatalineScatters: i64 = 0

	progressStopwatch: time.Stopwatch
	time.stopwatch_start(&progressStopwatch)
	lastProgressLogTime: time.Duration

	batchTxCount: i32 = 1
	maxBatchRxCount := min(receiveChannelCount, DATALINE_BATCH_SIZE)
	batchSize := simulator.info.scattererBatchSize > 0 ? i32(simulator.info.scattererBatchSize) : SCATTER_BATCH_SIZE

	stageStopwatch: time.Stopwatch
	time.stopwatch_start(&stageStopwatch)
	utility.prof_begin("Allocate")
	data = make_aligned([]f32, sampleCount * receiveChannelCount * transmissionCount, 16)
	elementImpulses := make([]ImpulseResponse, int(min(batchSize, scatterCount)) * len(elements), context.allocator)
	transmissionSampleRanges := make([]SampleRange, int(min(batchSize, scatterCount)) * int(batchTxCount), context.allocator)
	transmissionImpulses := make_aligned([]f32, int(min(batchSize, scatterCount)) * int(batchTxCount) * int(sampleCount), 16, context.allocator)
	scatterBatchMemory := assert(
		mem.alloc_bytes_non_zeroed(
			scatter_batch_memory_size(sampleCount, batchTxCount, maxBatchRxCount, scatterCount, batchSize),
			align_of(u8),
			context.allocator,
		),
	)
	scatterArena: mem.Arena
	mem.arena_init(&scatterArena, scatterBatchMemory)
	scatterAllocator := mem.arena_allocator(&scatterArena)
	defer delete(elementImpulses)
	defer delete(transmissionSampleRanges)
	defer delete(transmissionImpulses)
	defer delete(scatterBatchMemory)
	utility.prof_end()
	when CPU_STAGE_TIMING {
		cpu_stage_timing_add(&timing.allocation, &stageStopwatch)
	}

	// TODO: Choose where to put the scatter scaling

	for scatterBatchStart: i32 = 0; scatterBatchStart < scatterCount; scatterBatchStart += batchSize {
		scatterBatchEnd := min(scatterBatchStart + batchSize, scatterCount)
		scatterBatchCount := scatterBatchEnd - scatterBatchStart

		when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
		utility.prof_begin("Element SIR Calculation")
		for scatter, scatterIndex in scatters[scatterBatchStart:scatterBatchEnd] {
			scatterElementImpulses := elementImpulses[scatterIndex * auto_cast len(elements):][:len(elements)]
			for element, elementIndex in elements {
				scatterElementImpulses[elementIndex] = get_spatial_impulse_response(speedOfSound, samplingFrequency, element, scatter)
			}
		}
		utility.prof_end()
		when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.elementResponses, &stageStopwatch)

		for transmission, transmissionIndex in transmissions {
			when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
			utility.prof_begin("Transmission Impulse Calculation")
			for _, scatterIndex in scatters[scatterBatchStart:scatterBatchEnd] {
				scatterElementImpulses := elementImpulses[scatterIndex * auto_cast len(elements):][:len(elements)]

				transmissionSampleRange: SampleRange = {max(i32), min(i32)}
				for element in transmission.elements {
					elementImpulse := scatterElementImpulses[element.index]
					elementImpulse.rect += element.delay * samplingFrequency
					elementImpulse.scale *= element.apodization
					if elementImpulse.scale == 0 do continue

					transmissionSampleRange.minSample = min(transmissionSampleRange.minSample, i32(linalg.floor(elementImpulse.rect.x - 0.5)))
					transmissionSampleRange.maxSample = max(transmissionSampleRange.maxSample, i32(linalg.ceil(elementImpulse.rect.w + 0.5)))
				}

				transmissionSampleRanges[scatterIndex] = transmissionSampleRange
				transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
				transmissionImpulse := transmissionImpulses[scatterIndex * int(sampleCount):][:transmissionSampleCount]
				slice.zero(transmissionImpulse)

				for element in transmission.elements {
					elementImpulse := scatterElementImpulses[element.index]
					elementImpulse.rect += element.delay * samplingFrequency
					elementImpulse.scale *= element.apodization

					if elementImpulse.scale == 0 do continue

					elementMinSample := i32(linalg.floor(elementImpulse.rect.x - 0.5))
					elementMaxSample := i32(linalg.ceil(elementImpulse.rect.w + 0.5))

					sample_aperture_add(
						transmissionImpulse[(elementMinSample - transmissionSampleRange.minSample):(elementMaxSample + 1 - transmissionSampleRange.minSample)],
						elementMinSample,
						elementImpulse,
						auto_cast cumulative,
					)
				}
			}
			utility.prof_end()
			when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.transmitCoalesce, &stageStopwatch)

			for rxBatchStart: i32 = 0; rxBatchStart < receiveChannelCount; rxBatchStart += DATALINE_BATCH_SIZE {
				rxBatchEnd := min(rxBatchStart + DATALINE_BATCH_SIZE, receiveChannelCount)
				batchRxCount := rxBatchEnd - rxBatchStart

				timeDomainScatters := make([dynamic]CpuScatterData, 0, scatterBatchCount, scatterAllocator)
				frequencyDomainScatters := make([dynamic]CpuScatterData, 0, scatterBatchCount, scatterAllocator)

				when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
				for scatter, scatterIndex in scatters[scatterBatchStart:scatterBatchEnd] {
					scatterElementImpulses := elementImpulses[scatterIndex * auto_cast len(elements):][:len(elements)]

					utility.prof_scoped("Scatterer Impulse")

					receiveChannelSampleRangesMemory := assert(
						mem.arena_alloc_non_zeroed(&scatterArena, int(batchRxCount) * size_of(SampleRange), align_of(SampleRange)),
					)
					receiveChannelImpulsesMemory := assert(mem.arena_alloc_non_zeroed(&scatterArena, int(batchRxCount) * int(sampleCount) * size_of(f32), 16))
					scatterData: CpuScatterData = {
						scatter                    = scatter,
						transmissionSampleRanges   = transmissionSampleRanges[scatterIndex * int(batchTxCount):(scatterIndex + 1) * int(batchTxCount)],
						receiveChannelSampleRanges = slice.from_ptr(cast(^SampleRange)receiveChannelSampleRangesMemory, int(batchRxCount)),
						transmissionImpulses       = transmissionImpulses[scatterIndex * int(
							batchTxCount,
						) * int(sampleCount):(scatterIndex + 1) * int(batchTxCount) * int(sampleCount)],
						receiveChannelImpulses     = slice.from_ptr(cast(^f32)receiveChannelImpulsesMemory, int(batchRxCount) * int(sampleCount)),
					}

					utility.prof_begin("Receive Channel Impulse")
					for rxIndex in rxBatchStart ..< rxBatchEnd {
						receiveChannel := receiveChannels[rxIndex]
						localRxIndex := rxIndex - rxBatchStart

						utility.prof_begin("Receive Channel Precalculations")
						receiveChannelSampleRange: SampleRange = {max(i32), min(i32)}
						for element in receiveChannel.elements {
							elementImpulse := scatterElementImpulses[element.index]
							elementImpulse.rect += element.delay * samplingFrequency
							elementImpulse.scale *= element.apodization
							// One of the impulse responses needs to be offset by the start time
							elementImpulse.rect -= startTime * samplingFrequency
							// Necessary for proper delaying in the cumulative case
							if cumulative do elementImpulse.rect -= 1
							if elementImpulse.scale == 0 do continue

							receiveChannelSampleRange.minSample = min(receiveChannelSampleRange.minSample, i32(linalg.floor(elementImpulse.rect.x - 0.5)))
							receiveChannelSampleRange.maxSample = max(receiveChannelSampleRange.maxSample, i32(linalg.ceil(elementImpulse.rect.w + 0.5)))
						}

						scatterData.receiveChannelSampleRanges[localRxIndex] = receiveChannelSampleRange
						receiveChannelSampleCount := sample_range_sample_count(receiveChannelSampleRange)
						receiveChannelImpulse := scatterData.receiveChannelImpulses[localRxIndex * auto_cast sampleCount:][:receiveChannelSampleCount]
						slice.zero(receiveChannelImpulse)
						utility.prof_end()

						utility.prof_begin("Receive Channel Sampling")
						for element in receiveChannel.elements {
							elementImpulse := scatterElementImpulses[element.index]
							elementImpulse.rect += element.delay * samplingFrequency
							elementImpulse.scale *= element.apodization
							// One of the impulse responses needs to be offset by the start time
							elementImpulse.rect -= startTime * samplingFrequency
							// Necessary for proper delaying in the cumulative case
							if cumulative do elementImpulse.rect -= 1

							if elementImpulse.scale == 0 do continue

							elementMinSample := i32(linalg.floor(elementImpulse.rect.x - 0.5))
							elementMaxSample := i32(linalg.ceil(elementImpulse.rect.w + 0.5))

							sample_aperture_add(
								receiveChannelImpulse[(elementMinSample - receiveChannelSampleRange.minSample):(elementMaxSample +
									1 -
									receiveChannelSampleRange.minSample)],
								elementMinSample,
								elementImpulse,
								auto_cast cumulative,
							)
						}
						utility.prof_end()
					}
					utility.prof_end()

					maxTransmissionSampleCount, maxReceiveChannelSampleCount: i32
					for transmissionSampleRange in scatterData.transmissionSampleRanges {
						maxTransmissionSampleCount = max(maxTransmissionSampleCount, sample_range_sample_count(transmissionSampleRange))
					}
					for receiveChannelSampleRange in scatterData.receiveChannelSampleRanges {
						maxReceiveChannelSampleCount = max(maxReceiveChannelSampleCount, sample_range_sample_count(receiveChannelSampleRange))
					}
					fftCount := pffft.adjust_n(auto_cast (maxTransmissionSampleCount + maxReceiveChannelSampleCount - 1))
					scatterData.fftCount = auto_cast fftCount

					if fftCount < 128 {
						append(&timeDomainScatters, scatterData)
					} else {
						append(&frequencyDomainScatters, scatterData)
					}
				}
				when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.receiveCoalesce, &stageStopwatch)

				if len(timeDomainScatters) > 0 {
					when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
					convolve_time_domain(
						sampleCount,
						batchTxCount,
						batchRxCount,
						timeDomainScatters[:],
						data[(rxBatchStart + auto_cast transmissionIndex * receiveChannelCount) * sampleCount:],
					)
					when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.convolution, &stageStopwatch)
				}
				if len(frequencyDomainScatters) > 0 {
					when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
					convolve_frequency_domain(
						sampleCount,
						batchTxCount,
						batchRxCount,
						frequencyDomainScatters[:],
						data[(rxBatchStart + auto_cast transmissionIndex * receiveChannelCount) * sampleCount:],
					)
					when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.convolution, &stageStopwatch)
				}
				mem.arena_free_all(&scatterArena)

				completedDatalineScatters += i64(scatterBatchCount) * i64(batchTxCount) * i64(batchRxCount)
				elapsedDuration := time.stopwatch_duration(progressStopwatch)
				if elapsedDuration >= PROGRESS_LOG_DELAY_THRESHOLD {
					if lastProgressLogTime == 0 || elapsedDuration - lastProgressLogTime >= PROGRESS_LOG_INTERVAL {
						lastProgressLogTime = elapsedDuration
						fraction := f64(completedDatalineScatters) / f64(totalDatalineScatters)
						percentage := fraction * 100.0
						if fraction > 0 {
							estimatedTotalDuration := time.Duration(f64(elapsedDuration) / fraction)
							estimatedRemainingDuration := max(estimatedTotalDuration - elapsedDuration, 0)
							log.infof(
								"Simulation progress: %.1f%%, estimated completion in %v (elapsed: %v)",
								percentage,
								estimatedRemainingDuration,
								elapsedDuration,
							)
						} else {
							log.infof("Simulation progress: %.1f%% (elapsed: %.1fs)", percentage, elapsedDuration)
						}
					}
				}
			}
		}
	}

	when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
	apply_temporal_responses(data, sampleCount, 1 / samplingFrequency, transmissions, receiveChannels, impulses, excitations)
	when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.temporal, &stageStopwatch)
	when CPU_STAGE_TIMING {
		time.stopwatch_stop(&totalStopwatch)
		simulator.timing.stages = timing
		simulator.timing.simulation = time.stopwatch_duration(totalStopwatch)
	}
	return
}

apply_temporal_responses :: proc(
	data: []f32,
	sampleCount: i32,
	sampleInterval: f32,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	impulses: []TransducerImpulse,
	excitations: []Excitation,
) {
	maxResponseLength: i32 = 1
	for response in impulses do maxResponseLength = max(maxResponseLength, i32(len(response)))
	for response in excitations do maxResponseLength = max(maxResponseLength, i32(len(response)))

	current := make_aligned([]f32, sampleCount, 16, context.allocator)
	next := make_aligned([]f32, sampleCount, 16, context.allocator)
	defer delete(current)
	defer delete(next)

	for transmission, transmissionIndex in transmissions {
		for receiveChannel, receiveChannelIndex in receiveChannels {
			lineOffset := (receiveChannelIndex + transmissionIndex * len(receiveChannels)) * int(sampleCount)
			line := data[lineOffset:lineOffset + int(sampleCount)]
			copy(current, line)

			if transmission.impulse != 0 {
				convolve_temporal_response(current, next, impulses[int(transmission.impulse) - 1], sampleInterval)
				temporary := current
				current = next
				next = temporary
			}
			if transmission.excitation != 0 {
				convolve_temporal_response(current, next, excitations[int(transmission.excitation) - 1], sampleInterval)
				temporary := current
				current = next
				next = temporary
			}
			if receiveChannel.impulse != 0 {
				convolve_temporal_response(current, next, impulses[int(receiveChannel.impulse) - 1], sampleInterval)
				temporary := current
				current = next
				next = temporary
			}
			copy(line, current)
		}
	}
}

convolve_temporal_response :: proc(current, next: []f32, response: $T, sampleInterval: f32) {
	if len(response) == 0 do return
	slice.zero(next)
	for outputIndex in 0 ..< len(current) {
		firstInput := max(0, outputIndex - len(response) + 1)
		for inputIndex in firstInput ..< outputIndex + 1 {
			next[outputIndex] += current[inputIndex] * response[outputIndex - inputIndex] * sampleInterval
		}
	}
}

convolve_time_domain :: proc(sampleCount, transmissionCount, receiveChannelCount: i32, scatters: []CpuScatterData, data: []f32) {
	utility.prof_scoped(#procedure)
	for transmissionIndex in 0 ..< transmissionCount {
		utility.prof_scoped("Transmission")
		for receiveChannelIndex in 0 ..< receiveChannelCount {
			utility.prof_scoped("Receive Channel")
			#no_bounds_check receiveDataLine := data[(receiveChannelIndex + (transmissionIndex * receiveChannelCount)) * auto_cast sampleCount:][:sampleCount]

			utility.prof_begin("Check Sample Range")
			minSample := auto_cast sampleCount
			maxSample: i32 = 0
			for scatterIndex: i32 = 0; scatterIndex < auto_cast len(scatters); scatterIndex += 1 {
				scatterData := scatters[scatterIndex]
				transmissionSampleRange := scatterData.transmissionSampleRanges[transmissionIndex]
				transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
				transmissionMinSample := transmissionSampleRange.minSample
				receiveChannelSampleRange := scatterData.receiveChannelSampleRanges[receiveChannelIndex]
				receiveChannelSampleCount := sample_range_sample_count(receiveChannelSampleRange)
				receiveChannelMinSample := receiveChannelSampleRange.minSample
				minSample = min(minSample, max(transmissionMinSample + receiveChannelMinSample, 0))
				maxSample = max(
					maxSample,
					min(transmissionMinSample + transmissionSampleCount + receiveChannelMinSample + receiveChannelSampleCount - 1, auto_cast sampleCount),
				)
			}
			utility.prof_end()
			if minSample >= maxSample do continue

			for baseSample := minSample; baseSample < maxSample; baseSample += SIMD32_WIDTH {
				samples := baseSample + simd.iota(SIMD_I32)
				sampleMask := simd.lanes_lt(samples, SIMD_I32(maxSample))
				sum := SIMD_F32(0)

				for scatterIndex: i32 = 0; scatterIndex < auto_cast len(scatters); scatterIndex += 1 {
					scatterData := scatters[scatterIndex]
					transmissionSampleRange := scatterData.transmissionSampleRanges[transmissionIndex]
					transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
					receiveChannelSampleRange := scatterData.receiveChannelSampleRanges[receiveChannelIndex]
					receiveChannelSampleCount := sample_range_sample_count(receiveChannelSampleRange)
					scatterMinSample := max(transmissionSampleRange.minSample + receiveChannelSampleRange.minSample, 0)
					scatterMaxSample := min(
						transmissionSampleRange.minSample + transmissionSampleCount + receiveChannelSampleRange.minSample + receiveChannelSampleCount - 1,
						auto_cast sampleCount,
					)
					scatterMask := simd.bit_and(
						sampleMask,
						simd.bit_and(simd.lanes_ge(samples, SIMD_I32(scatterMinSample)), simd.lanes_lt(samples, SIMD_I32(scatterMaxSample))),
					)
					if scatterMinSample >= scatterMaxSample do continue

					transmissionImpulse := scatterData.transmissionImpulses[transmissionIndex * auto_cast sampleCount:][:transmissionSampleCount]
					receiveChannelImpulse := scatterData.receiveChannelImpulses[receiveChannelIndex * auto_cast sampleCount:][:receiveChannelSampleCount]
					transmissionMaxSample := transmissionSampleRange.minSample + transmissionSampleCount - 1
					receiveChannelMaxSample := receiveChannelSampleRange.minSample + receiveChannelSampleCount - 1
					minK := max(transmissionSampleRange.minSample, baseSample - receiveChannelMaxSample)
					maxK := min(transmissionMaxSample, min(baseSample + SIMD32_WIDTH, scatterMaxSample) - receiveChannelSampleRange.minSample)
					if minK > maxK do continue

					scatterSum := SIMD_F32(0)
					for k in minK ..= maxK {
						kt := k - transmissionSampleRange.minSample
						#no_bounds_check tSamples := SIMD_F32(transmissionImpulse[kt])
						kr := samples - k - receiveChannelSampleRange.minSample
						kr0 := baseSample - k - receiveChannelSampleRange.minSample
						krMask := simd.bit_and(simd.lanes_ge(kr, 0), simd.lanes_lt(kr, SIMD_I32(receiveChannelSampleCount)))
						#no_bounds_check rSamples := simd.masked_load(cast(^SIMD_F32)raw_data(receiveChannelImpulse[kr0:]), SIMD_F32(0), krMask)
						scatterSum += tSamples * rSamples
					}
					sum += simd.select(SIMD_U32(scatterMask), scatterSum, SIMD_F32(0))
				}

				#no_bounds_check dataPtr := cast(^SIMD_F32)raw_data(receiveDataLine[baseSample:])
				d := simd.masked_load(dataPtr, SIMD_F32(0), sampleMask)
				d += sum
				simd.masked_store(dataPtr, d, sampleMask)
			}
		}
	}
}

convolve_frequency_domain :: proc(sampleCount, transmissionCount, receiveChannelCount: i32, scatters: []CpuScatterData, data: []f32) {
	utility.prof_scoped(#procedure)

	maxFftCount: i32
	for scatterData in scatters {
		maxFftCount = max(maxFftCount, scatterData.fftCount)
	}

	transmissionFourier := make_aligned([]f32, maxFftCount, 16, context.allocator)
	receiveChannelFourier := make_aligned([]f32, maxFftCount, 16, context.allocator)
	convolutionData := make_aligned([]f32, maxFftCount, 16, context.allocator)
	defer {
		delete(transmissionFourier)
		delete(receiveChannelFourier)
		delete(convolutionData)
	}

	for transmissionIndex in 0 ..< transmissionCount {
		utility.prof_scoped("Transmission")
		for receiveChannelIndex in 0 ..< receiveChannelCount {
			utility.prof_scoped("Receive Channel")
			#no_bounds_check receiveDataLine := data[(receiveChannelIndex + (transmissionIndex * receiveChannelCount)) * auto_cast sampleCount:][:sampleCount]
			for scatterData in scatters {
				utility.prof_scoped("Scatterer")
				transmissionSampleRange := scatterData.transmissionSampleRanges[transmissionIndex]
				transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
				receiveChannelSampleRange := scatterData.receiveChannelSampleRanges[receiveChannelIndex]
				receiveChannelSampleCount := sample_range_sample_count(receiveChannelSampleRange)
				minSample := max(transmissionSampleRange.minSample + receiveChannelSampleRange.minSample, 0)
				maxSample := min(transmissionSampleRange.maxSample + receiveChannelSampleRange.maxSample + 1, sampleCount)
				if minSample >= maxSample do continue

				fftCount := pffft.adjust_n(auto_cast (transmissionSampleCount + receiveChannelSampleCount - 1))
				pffftSession := pffft.new_setup(fftCount, .REAL)
				assert(pffftSession != nil)

				transmissionImpulse := scatterData.transmissionImpulses[transmissionIndex * sampleCount:][:transmissionSampleCount]
				receiveChannelImpulse := scatterData.receiveChannelImpulses[receiveChannelIndex * sampleCount:][:receiveChannelSampleCount]
				slice.zero(transmissionFourier[:fftCount])
				slice.zero(receiveChannelFourier[:fftCount])
				copy(transmissionFourier[:transmissionSampleCount], transmissionImpulse)
				copy(receiveChannelFourier[:receiveChannelSampleCount], receiveChannelImpulse)
				pffft.transform(pffftSession, raw_data(transmissionFourier), raw_data(transmissionFourier), raw_data(convolutionData), .FORWARD)
				pffft.transform(pffftSession, raw_data(receiveChannelFourier), raw_data(receiveChannelFourier), raw_data(convolutionData), .FORWARD)

				slice.zero(convolutionData[:fftCount])
				pffft.zconvolve_accumulate(
					pffftSession,
					raw_data(transmissionFourier),
					raw_data(receiveChannelFourier),
					raw_data(convolutionData),
					1.0 / f32(fftCount),
				)
				pffft.transform(pffftSession, raw_data(convolutionData), raw_data(convolutionData), raw_data(transmissionFourier), .BACKWARD)
				pffft.destroy_setup(pffftSession)

				startSample := transmissionSampleRange.minSample + receiveChannelSampleRange.minSample
				for sample := minSample; sample < maxSample; sample += 1 {
					receiveDataLine[sample] += convolutionData[sample - startSample]
				}
			}
		}
	}
}

CpuScatterData :: struct {
	scatter:                    Scatter,
	transmissionSampleRanges:   []SampleRange,
	receiveChannelSampleRanges: []SampleRange,
	transmissionImpulses:       []f32,
	receiveChannelImpulses:     []f32,
	fftCount:                   i32,
}

scatter_batch_memory_size :: proc(
	sampleCount, transmissionCount, receiveChannelCount, scatterCount: i32,
	scattererBatchSize: i32 = SCATTER_BATCH_SIZE,
) -> int {
	batchSize := int(min(scattererBatchSize, scatterCount))
	maxRx := int(min(DATALINE_BATCH_SIZE, receiveChannelCount))
	receiveChannelMetadataSize := maxRx * size_of(SampleRange)
	receiveChannelImpulseSize := maxRx * int(sampleCount) * size_of(f32)

	scatterDataSize := arena_allocation_size(receiveChannelMetadataSize, align_of(SampleRange)) + arena_allocation_size(receiveChannelImpulseSize, 16)
	batchCollectionSize := 2 * arena_allocation_size(batchSize * size_of(CpuScatterData), align_of(CpuScatterData))
	return batchCollectionSize + batchSize * scatterDataSize

	arena_allocation_size :: proc(byteCount, alignment: int) -> int {
		return byteCount + alignment - 1
	}
}

SIMD32_WIDTH :: 16
SIMD_F32 :: #simd[SIMD32_WIDTH]f32
SIMD_I32 :: #simd[SIMD32_WIDTH]i32
SIMD_U32 :: #simd[SIMD32_WIDTH]u32

get_spatial_impulse_response :: proc(
	speedOfSound, samplingFrequency: f32,
	element: RectangularElement,
	scatter: Scatter,
) -> (
	impulseResponse: ImpulseResponse,
) {
	scatterPosition := scatter.position - element.position
	rotationAxis := linalg.cross(element.normal, [3]f32{0, 0, 1})
	rotationCosine := element.normal[2]
	rotationAxisLengthSquared := linalg.dot(rotationAxis, rotationAxis)
	if rotationAxisLengthSquared < linalg.F32_EPSILON {
		if rotationCosine < 0 {
			scatterPosition = [3]f32{-scatterPosition[0], scatterPosition[1], -scatterPosition[2]}
		}
	} else {
		scatterPosition =
			rotationCosine * scatterPosition +
			linalg.cross(rotationAxis, scatterPosition) +
			(1 - rotationCosine) / rotationAxisLengthSquared * rotationAxis * linalg.dot(rotationAxis, scatterPosition)
	}
	dieProjection := linalg.abs(element.size * scatterPosition.xy)
	distance := linalg.length(scatterPosition)

	// We do not consider scatterers that are to close to the transducer due
	// to a singularity in the response
	DISTANCE_EPSILON :: 1e-4
	if distance < DISTANCE_EPSILON {
		impulseResponse.rect = {0, 0, 0, 0}
		impulseResponse.scale = 0
		return
	}

	t0 := distance / speedOfSound
	dt1 := linalg.min_single(dieProjection) / distance / speedOfSound
	dt2 := linalg.max_single(dieProjection) / distance / speedOfSound

	rectTimes := t0 + 0.5 * (dt1 * [4]f32{-1, +1, -1, +1} + dt2 * [4]f32{-1, -1, +1, +1}) + element.delay
	impulseResponse.rect = rectTimes * samplingFrequency
	dt := 1 / samplingFrequency

	powerDenominator := (impulseResponse.rect.w - impulseResponse.rect.x) <= 1 ? dt : dt2
	impulseResponse.scale =
		linalg.sqrt(scatter.amplitude) * element.apodization * element.size.x * element.size.y / (2 * linalg.PI * distance * powerDenominator)
	return
}

sample_aperture_into :: proc(samples: []f32, minSample: i32, impulseResponse: ImpulseResponse, cumulative: bool) {
	sampleCount := len(samples)
	for chunkBase: i32 = 0; chunkBase < auto_cast sampleCount; chunkBase += SIMD32_WIDTH {
		indices := chunkBase + simd.iota(SIMD_I32)
		mask := simd.lanes_lt(indices, SIMD_I32(sampleCount))

		chunkSamples := sample_aperture(indices + minSample, impulseResponse.rect, cumulative)
		chunkSamples *= impulseResponse.scale
		#no_bounds_check {
			simd.masked_store(cast(^SIMD_F32)raw_data(samples[int(chunkBase):]), chunkSamples, mask)
		}
	}
}

sample_aperture_add :: proc(samples: []f32, minSample: i32, impulseResponse: ImpulseResponse, cumulative: bool) {
	sampleCount := len(samples)
	for chunkBase: i32 = 0; chunkBase < auto_cast sampleCount; chunkBase += SIMD32_WIDTH {
		indices := chunkBase + simd.iota(SIMD_I32)
		mask := simd.lanes_lt(indices, SIMD_I32(sampleCount))

		chunkSamples := sample_aperture(indices + minSample, impulseResponse.rect, cumulative)
		chunkSamples *= impulseResponse.scale

		chunkSamples += simd.masked_load(cast(^SIMD_F32)raw_data(samples[int(chunkBase):]), SIMD_F32(0), mask)
		simd.masked_store(cast(^SIMD_F32)raw_data(samples[int(chunkBase):]), chunkSamples, mask)
	}
}

sample_aperture :: #force_inline proc(n: SIMD_I32, aperture: [4]f32, cumulative: bool) -> (result: SIMD_F32) {
	return (!cumulative) ? sample_aperture_discrete(n, aperture) : sample_aperture_cumulative(n, aperture) - sample_aperture_cumulative(n - 1, aperture)
}

sample_aperture_discrete :: proc(n: SIMD_I32, aperture: [4]f32) -> (result: SIMD_F32) {
	le :: simd.lanes_le
	gt :: simd.lanes_gt
	ge :: simd.lanes_ge
	and :: simd.bit_and
	select :: simd.select

	nf := cast(SIMD_F32)n
	value := SIMD_F32(0)

	if qDelta := aperture.w - aperture.x <= 1; qDelta {
		sDelta := 1 - simd.abs(nf - aperture.x)
		return simd.clamp(sDelta, SIMD_F32(0), SIMD_F32(1))
	}

	if qRect := aperture.y - aperture.x <= linalg.F32_EPSILON; qRect {
		qRectLeft := and(ge(nf, SIMD_F32(aperture.y - 0.5)), le(nf, SIMD_F32(aperture.y + 0.5)))
		sRectLeft := nf - (aperture.y - 0.5)
		value = select(SIMD_U32(and(SIMD_U32(qRect), qRectLeft)), sRectLeft, value)
		qRectCenter := and(gt(nf, SIMD_F32(aperture.y + 0.5)), le(nf, SIMD_F32(aperture.z - 0.5)))
		sRectCenter := SIMD_F32(1)
		value = select(SIMD_U32(and(SIMD_U32(qRect), qRectCenter)), sRectCenter, value)
		qRectRight := and(gt(nf, SIMD_F32(aperture.z - 0.5)), le(nf, SIMD_F32(aperture.z + 0.5)))
		sRectRight := 1 - (nf - (aperture.z - 0.5))
		value = select(SIMD_U32(and(SIMD_U32(qRect), qRectRight)), sRectRight, value)
		return simd.clamp(value, SIMD_F32(0), SIMD_F32(1))
	}

	if qTri := aperture.z - aperture.y <= linalg.F32_EPSILON; qTri {
		qTriLeft := and(ge(nf, SIMD_F32(aperture.x)), le(nf, SIMD_F32(aperture.y)))
		sTriLeft := (nf - aperture.x) / (aperture.y - aperture.x + linalg.F32_EPSILON)
		value = select(SIMD_U32(and(SIMD_U32(qTri), qTriLeft)), sTriLeft, value)
		qTriRight := and(gt(nf, SIMD_F32(aperture.z)), le(nf, SIMD_F32(aperture.w)))
		sTriRight := (1 - (nf - aperture.z) / (aperture.w - aperture.z + linalg.F32_EPSILON))
		value = select(SIMD_U32(and(SIMD_U32(qTri), qTriRight)), sTriRight, value)
		return simd.clamp(value, SIMD_F32(0), SIMD_F32(1))
	}

	if qTrap := true; qTrap {
		qTrapLeft := and(ge(nf, SIMD_F32(aperture.x)), le(nf, SIMD_F32(aperture.y)))
		sTrapLeft := (nf - aperture.x) / (aperture.y - aperture.x + linalg.F32_EPSILON)
		value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapLeft)), sTrapLeft, value)
		qTrapCenter := and(gt(nf, SIMD_F32(aperture.y)), le(nf, SIMD_F32(aperture.z)))
		sTrapCenter := SIMD_F32(1)
		value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapCenter)), sTrapCenter, value)
		qTrapRight := and(gt(nf, SIMD_F32(aperture.z)), le(nf, SIMD_F32(aperture.w)))
		sTrapRight := (1 - (nf - aperture.z) / (aperture.w - aperture.z + linalg.F32_EPSILON))
		value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapRight)), sTrapRight, value)
		return simd.clamp(value, SIMD_F32(0), SIMD_F32(1))
	}
	return
}

sample_aperture_cumulative :: proc(n: SIMD_I32, aperture: [4]f32) -> (result: SIMD_F32) {
	ge :: simd.lanes_ge
	or :: simd.bit_or
	select :: simd.select
	clamp :: simd.clamp

	nf := cast(SIMD_F32)n
	value := SIMD_F32(0)

	qDelta := aperture.w - aperture.x <= 1
	qRect := !qDelta && (aperture.y - aperture.x <= linalg.F32_EPSILON)
	qTri := !qDelta && !qRect && (aperture.z - aperture.y <= linalg.F32_EPSILON)
	qTrap := !(qDelta | qRect | qTri)

	if qDelta {
		return select(ge(nf, SIMD_F32(aperture.x)), SIMD_F32(1), SIMD_F32(0))
	}

	if qRect | qTrap {
		dy := aperture.z - aperture.y
		sRect := dy <= 0 ? SIMD_F32(0) : dy * clamp((nf - aperture.y) / dy, SIMD_F32(0), SIMD_F32(1))
		value += sRect
	}

	if qTri | qTrap {
		dxLeft := aperture.y - aperture.x
		sTriLeftSat := dxLeft <= 0 ? SIMD_F32(0) : clamp((nf - aperture.x) / dxLeft, SIMD_F32(0), SIMD_F32(1))
		sTriLeft := 0.5 * dxLeft * sTriLeftSat * sTriLeftSat

		dxRight := aperture.w - aperture.z
		sTriRightSat := dxRight <= 0 ? SIMD_F32(0) : clamp((aperture.w - nf) / dxRight, SIMD_F32(0), SIMD_F32(1))
		sTriRight := 0.5 * dxRight * (1 - sTriRightSat * sTriRightSat)

		value += sTriLeft + sTriRight
	}

	return value
}
