package ekhos

import "base:intrinsics"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:simd"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import ekhos_thread "ekhos:thread"
import utility "ekhos:utility"
import "import:pffft"

assert :: utility.assert

cpuSimulator :: struct {
	info:      cpuSimulationInfo,
	timing:    CpuTiming,
	allocator: mem.Allocator,
	lanes:     []ekhos_thread.Lane,
	threads:   []^thread.Thread,
	job:       CpuSimulationJob,
	stop:      bool,
}

CpuSimulationJob :: struct {
	settings:        ^SimulationSettings,
	transmissions:   []Transmission,
	receiveChannels: []ReceiveChannel,
	elements:        #soa[]RectangularElement,
	scatters:        []Scatter,
	impulses:        []TransducerImpulse,
	excitations:     []Excitation,
	data:            []f32,
}

CpuWorker :: struct {
	simulator: ^cpuSimulator,
	lane:      ^ekhos_thread.Lane,
	allocator: mem.Allocator,
}

cpuSimulationInfo :: struct {
	apertureSampleCount: u32,
	scattererBatchSize:  u32,
}

CpuTiming :: struct {
	planning:   time.Duration,
	simulation: time.Duration,
	stages:     CpuStageTiming,
}

resolve_cpu_thread_count :: proc(threadCount: u32) -> int {
	if threadCount == 0 {
		return max(os.get_processor_core_count(), 1)
	}
	return int(threadCount)
}

create_cpu_simulator :: proc(threadCount: int = 1) -> (simulator: cpuSimulator, ok := true) {
	threadCount := threadCount
	threadCount = max(threadCount, 1)
	simulator.allocator = context.allocator
	simulator.lanes = ekhos_thread.open_lane_group(threadCount, simulator.allocator)
	simulator.threads = make([]^thread.Thread, max(threadCount - 1, 0), simulator.allocator)
	return
}

destroy_cpu_simulator :: proc(simulator: ^cpuSimulator) {
	if len(simulator.lanes) == 0 do return
	simulator.stop = true
	ekhos_thread.laneSync(&simulator.lanes[0])
	ekhos_thread.laneSync(&simulator.lanes[0])
	for worker in simulator.threads do thread.destroy(worker)
	ekhos_thread.close_lane_group(len(simulator.lanes), simulator.allocator, simulator.lanes)
	delete(simulator.threads, simulator.allocator)
	delete(simulator.lanes, simulator.allocator)
	simulator^ = {}
}

plan_cpu_simulation :: proc(simulator: ^cpuSimulator, settings: ^SimulationSettings) -> (ok := true) {
	info := simulator.info
	threadCount := resolve_cpu_thread_count(settings.cpuSettings.threadCount)
	if len(simulator.lanes) != threadCount {
		destroy_cpu_simulator(simulator)
		simulator^, ok = create_cpu_simulator(threadCount)
		if !ok do return
		for laneIndex in 1 ..< threadCount {
			worker := new(CpuWorker, simulator.allocator)
			worker.simulator = simulator
			worker.lane = &simulator.lanes[laneIndex]
			worker.allocator = simulator.allocator
			simulator.threads[laneIndex - 1] = thread.create_and_start_with_data(worker, cpu_worker_proc)
		}
	}
	simulator.info = info
	return
}

cpu_worker_proc :: proc(data: rawptr) {
	worker := cast(^CpuWorker)data
	utility.prof_thread_init()
	defer utility.prof_thread_deinit()
	defer free(worker, worker.allocator)
	simulator := worker.simulator
	for {
		ekhos_thread.laneSync(worker.lane)
		if simulator.stop {
			ekhos_thread.laneSync(worker.lane)
			return
		}
		simulate_cpu_lane(simulator, worker.lane)
		ekhos_thread.laneSync(worker.lane)
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
	jobSettings := settings
	simulator.job = {
		settings        = &jobSettings,
		transmissions   = transmissions,
		receiveChannels = receiveChannels,
		elements        = elements,
		scatters        = scatters,
		impulses        = impulses,
		excitations     = excitations,
	}
	ekhos_thread.laneSync(&simulator.lanes[0])
	data, ok = simulate_cpu_lane(simulator, &simulator.lanes[0])
	ekhos_thread.laneSync(&simulator.lanes[0])
	return
}

SCATTER_BATCH_SIZE :: 128
DATALINE_BATCH_SIZE :: 1024
CPU_WORK_CHUNK_SIZE :: 1
SCATTER_WORK_CHUNK_SIZE :: 8
PROGRESS_LOG_DELAY_THRESHOLD :: 20.0 * time.Second
PROGRESS_LOG_INTERVAL :: 20.0 * time.Second
CPU_STAGE_TIMING :: bool(#config(CPU_STAGE_TIMING, false))
CPU_TIME_DOMAIN_THRESHOLD :: int(#config(CPU_TIME_DOMAIN_THRESHOLD, 128))

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

cpu_stage_timing_max :: proc(total: ^time.Duration, value: time.Duration) {
	for {
		current := sync.atomic_load_explicit(total, .Relaxed)
		if value <= current do return
		_, exchanged := sync.atomic_compare_exchange_weak_explicit(total, current, value, .Relaxed, .Relaxed)
		if exchanged do return
	}
}

cpu_work_counter_claim :: proc(counter: ^i32, limit, chunkSize: i32) -> (start, end: i32, found: bool) {
	for {
		current := sync.atomic_load_explicit(counter, .Relaxed)
		if current >= limit do return
		next := min(current + chunkSize, limit)
		_, exchanged := sync.atomic_compare_exchange_weak_explicit(counter, current, next, .Relaxed, .Relaxed)
		if exchanged do return current, next, true
	}
}

log_cpu_timing :: proc(timing: CpuTiming, label: string, loc := #caller_location) {
	when CPU_STAGE_TIMING {
		log.infof("%s planning stage: %v", label, timing.planning, location = loc)
		log.infof(
			`
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
			timing.stages.allocation,
			timing.simulation > 0 ? 100 * f64(timing.stages.allocation) / f64(timing.simulation) : 0,
			timing.stages.elementResponses,
			timing.simulation > 0 ? 100 * f64(timing.stages.elementResponses) / f64(timing.simulation) : 0,
			timing.stages.transmitCoalesce,
			timing.simulation > 0 ? 100 * f64(timing.stages.transmitCoalesce) / f64(timing.simulation) : 0,
			timing.stages.receiveCoalesce,
			timing.simulation > 0 ? 100 * f64(timing.stages.receiveCoalesce) / f64(timing.simulation) : 0,
			timing.stages.convolution,
			timing.simulation > 0 ? 100 * f64(timing.stages.convolution) / f64(timing.simulation) : 0,
			timing.stages.temporal,
			timing.simulation > 0 ? 100 * f64(timing.stages.temporal) / f64(timing.simulation) : 0,
			timing.simulation,
			location = loc,
		)
	}
}

simulate_cpu_lane :: proc(simulator: ^cpuSimulator, lane: ^ekhos_thread.Lane) -> (data: []f32, ok := true) {

	utility.prof_scoped(#procedure)
	totalStopwatch: time.Stopwatch
	time.stopwatch_start(&totalStopwatch)

	settings := simulator.job.settings^
	transmissions := simulator.job.transmissions
	receiveChannels := simulator.job.receiveChannels
	elements := simulator.job.elements
	scatters := simulator.job.scatters
	impulses := simulator.job.impulses
	excitations := simulator.job.excitations
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

	batchTxCount := min(transmissionCount, DATALINE_BATCH_SIZE)
	batchRxCount := min(receiveChannelCount, DATALINE_BATCH_SIZE)
	batchSize := simulator.info.scattererBatchSize > 0 ? i32(simulator.info.scattererBatchSize) : SCATTER_BATCH_SIZE

	stageStopwatch: time.Stopwatch
	timing: CpuStageTiming
	sharedTiming: ^CpuTiming
	scatterWorkCounter: ^i32
	txWorkCounter: ^i32
	rxWorkCounter: ^i32
	dataLineWorkCounter: ^i32
	if ekhos_thread.laneIdx(lane) == 0 {
		simulator.timing.stages = {}
		simulator.timing.simulation = 0
		sharedTiming = &simulator.timing
		scatterWorkCounter = new(i32, simulator.allocator)
		txWorkCounter = new(i32, simulator.allocator)
		rxWorkCounter = new(i32, simulator.allocator)
		dataLineWorkCounter = new(i32, simulator.allocator)
	}
	ekhos_thread.laneSyncValue(lane, 0, &sharedTiming)
	ekhos_thread.laneSyncValue(lane, 0, &scatterWorkCounter)
	ekhos_thread.laneSyncValue(lane, 0, &txWorkCounter)
	ekhos_thread.laneSyncValue(lane, 0, &rxWorkCounter)
	ekhos_thread.laneSyncValue(lane, 0, &dataLineWorkCounter)
	defer if ekhos_thread.laneIdx(lane) == 0 {
		free(scatterWorkCounter, simulator.allocator)
		free(txWorkCounter, simulator.allocator)
		free(rxWorkCounter, simulator.allocator)
		free(dataLineWorkCounter, simulator.allocator)
	}
	time.stopwatch_start(&stageStopwatch)
	utility.prof_begin("Allocate")

	elementImpulses: []ImpulseResponse
	transmissionSampleRanges: []SampleRange
	transmissionImpulses: []f32
	receiveChannelSampleRanges: []SampleRange
	receiveChannelImpulses: []f32
	batchScatters: []CpuScatterData
	if ekhos_thread.laneIdx(lane) == 0 {
		data = make_aligned([]f32, sampleCount * receiveChannelCount * transmissionCount, 16)
		simulator.job.data = data
		elementImpulses = make([]ImpulseResponse, int(min(batchSize, scatterCount)) * len(elements), context.allocator)
		transmissionSampleRanges = make([]SampleRange, int(min(batchSize, scatterCount)) * int(batchTxCount), context.allocator)
		transmissionImpulses = make_aligned([]f32, int(min(batchSize, scatterCount)) * int(batchTxCount) * int(sampleCount), 16, context.allocator)
		receiveChannelSampleRanges = make([]SampleRange, int(min(batchSize, scatterCount)) * int(batchRxCount), context.allocator)
		receiveChannelImpulses = make_aligned([]f32, int(min(batchSize, scatterCount)) * int(batchRxCount) * int(sampleCount), 16, context.allocator)
		batchScatters = make([]CpuScatterData, int(min(batchSize, scatterCount)), context.allocator)
	}
	timeDomainScatters := make([dynamic]CpuScatterData, 0, int(min(batchSize, scatterCount)), context.allocator)
	frequencyDomainScatters := make([dynamic]CpuScatterData, 0, int(min(batchSize, scatterCount)), context.allocator)
	defer if ekhos_thread.laneIdx(lane) == 0 {
		delete(elementImpulses)
		delete(transmissionSampleRanges)
		delete(transmissionImpulses)
		delete(receiveChannelSampleRanges)
		delete(receiveChannelImpulses)
		delete(batchScatters)
	}
	defer delete(timeDomainScatters)
	defer delete(frequencyDomainScatters)

	pffftSetupCache := make(map[int]pffft.PffftSession, context.allocator)
	defer {
		for _, session in pffftSetupCache do pffft.destroy_setup(session)
		delete(pffftSetupCache)
	}

	ekhos_thread.laneSyncValue(lane, 0, &data)
	ekhos_thread.laneSyncValue(lane, 0, &elementImpulses)
	ekhos_thread.laneSyncValue(lane, 0, &transmissionSampleRanges)
	ekhos_thread.laneSyncValue(lane, 0, &transmissionImpulses)
	ekhos_thread.laneSyncValue(lane, 0, &receiveChannelSampleRanges)
	ekhos_thread.laneSyncValue(lane, 0, &receiveChannelImpulses)
	ekhos_thread.laneSyncValue(lane, 0, &batchScatters)
	utility.prof_end()

	when CPU_STAGE_TIMING {
		cpu_stage_timing_add(&timing.allocation, &stageStopwatch)
	}

	for scatterBatchStart: i32 = 0; scatterBatchStart < scatterCount; scatterBatchStart += batchSize {
		ekhos_thread.laneSync(lane)
		scatterBatchEnd := min(scatterBatchStart + batchSize, scatterCount)
		scatterBatchCount := scatterBatchEnd - scatterBatchStart
		if ekhos_thread.laneIdx(lane) == 0 do sync.atomic_store_explicit(scatterWorkCounter, 0, .Relaxed)
		ekhos_thread.laneSync(lane)

		when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
		utility.prof_begin("Element SIR Calculation")
		for {
			workStart, workEnd, found := cpu_work_counter_claim(scatterWorkCounter, scatterBatchCount, SCATTER_WORK_CHUNK_SIZE)
			if !found do break
			for scatterBatchIndex := workStart; scatterBatchIndex < workEnd; scatterBatchIndex += 1 {
				scatterIndex := scatterBatchStart + scatterBatchIndex
				scatter := scatters[scatterIndex]
				scatterElementImpulses := elementImpulses[scatterBatchIndex * auto_cast len(elements):][:len(elements)]
				for element, elementIndex in elements {
					scatterElementImpulses[elementIndex] = get_spatial_impulse_response(speedOfSound, samplingFrequency, element, scatter)
				}
			}
		}
		ekhos_thread.laneSync(lane)
		utility.prof_end()
		when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.elementResponses, &stageStopwatch)

		for txBatchStart: i32 = 0; txBatchStart < transmissionCount; txBatchStart += DATALINE_BATCH_SIZE {
			txBatchEnd := min(txBatchStart + DATALINE_BATCH_SIZE, transmissionCount)
			txBatchCount := txBatchEnd - txBatchStart

			// Coalesce Transmissions
			utility.prof_begin("Coalesce Transmissions")
			for {
				workStart, workEnd, found := cpu_work_counter_claim(txWorkCounter, txBatchCount, CPU_WORK_CHUNK_SIZE)
				if !found do break
				when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
				coalesce_impulses(
					transmissions[txBatchStart + workStart:][:workEnd - workStart],
					scatters[scatterBatchStart:scatterBatchEnd],
					elements,
					elementImpulses,
					transmissionSampleRanges,
					transmissionImpulses,
					sampleCount,
					batchTxCount,
					auto_cast workStart,
					samplingFrequency,
					0,
					cumulative,
					false,
				)
				when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.transmitCoalesce, &stageStopwatch)
			}
			utility.prof_end()

			for rxBatchStart: i32 = 0; rxBatchStart < receiveChannelCount; rxBatchStart += DATALINE_BATCH_SIZE {
				rxBatchEnd := min(rxBatchStart + DATALINE_BATCH_SIZE, receiveChannelCount)
				rxBatchCount := rxBatchEnd - rxBatchStart

				utility.prof_begin("Coalesce Receive Channels")
				for {
					workStart, workEnd, found := cpu_work_counter_claim(rxWorkCounter, rxBatchCount, CPU_WORK_CHUNK_SIZE)
					if !found do break
					when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
					coalesce_impulses(
						receiveChannels[rxBatchStart + workStart:][:workEnd - workStart],
						scatters[scatterBatchStart:scatterBatchEnd],
						elements,
						elementImpulses,
						receiveChannelSampleRanges,
						receiveChannelImpulses,
						sampleCount,
						batchRxCount,
						auto_cast workStart,
						samplingFrequency,
						startTime,
						cumulative,
						true,
					)
					when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.receiveCoalesce, &stageStopwatch)
				}
				utility.prof_end()

				ekhos_thread.laneSync(lane)
				if ekhos_thread.laneIdx(lane) == 0 {
					for scatterIndex in scatterBatchStart ..< scatterBatchEnd {
						localScatterIndex := scatterIndex - scatterBatchStart
						batchScatters[localScatterIndex] = {
							scatter                    = scatters[scatterIndex],
							transmissionSampleRanges   = transmissionSampleRanges[int(
								localScatterIndex,
							) * int(batchTxCount):int(localScatterIndex + 1) * int(batchTxCount)],
							receiveChannelSampleRanges = receiveChannelSampleRanges[int(localScatterIndex) * int(batchRxCount):][:int(batchRxCount)],
							transmissionImpulses       = transmissionImpulses[int(
								localScatterIndex,
							) * int(batchTxCount) * int(sampleCount):][:int(sampleCount) * int(batchTxCount)],
							receiveChannelImpulses     = receiveChannelImpulses[int(
								localScatterIndex,
							) * int(batchRxCount) * int(sampleCount):][:int(batchRxCount) * int(sampleCount)],
						}
					}
				}
				ekhos_thread.laneSync(lane)

				for {
					workStart, workEnd, found := cpu_work_counter_claim(dataLineWorkCounter, txBatchCount * rxBatchCount, CPU_WORK_CHUNK_SIZE)
					if !found do break
					for dataLineIndex := workStart; dataLineIndex < workEnd; dataLineIndex += 1 {
						transmissionIndex := dataLineIndex / rxBatchCount
						receiveChannelIndex := dataLineIndex % rxBatchCount
						clear(&timeDomainScatters)
						clear(&frequencyDomainScatters)
						for batchScatter in batchScatters[:scatterBatchCount] {
							transmissionSampleRange := batchScatter.transmissionSampleRanges[transmissionIndex]
							receiveChannelSampleRange := batchScatter.receiveChannelSampleRanges[receiveChannelIndex]
							transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
							receiveChannelSampleCount := sample_range_sample_count(receiveChannelSampleRange)
							fftCount := pffft.adjust_n(auto_cast (transmissionSampleCount + receiveChannelSampleCount - 1))
							scatterData := batchScatter
							scatterData.transmissionSampleRanges = batchScatter.transmissionSampleRanges[transmissionIndex:transmissionIndex + 1]
							scatterData.transmissionImpulses = batchScatter.transmissionImpulses[transmissionIndex *
							sampleCount:(transmissionIndex + 1) *
							sampleCount]
							scatterData.receiveChannelSampleRanges = batchScatter.receiveChannelSampleRanges[receiveChannelIndex:receiveChannelIndex + 1]
							scatterData.receiveChannelImpulses = batchScatter.receiveChannelImpulses[receiveChannelIndex *
							sampleCount:(receiveChannelIndex + 1) *
							sampleCount]
							scatterData.fftCount = auto_cast fftCount
							if fftCount < CPU_TIME_DOMAIN_THRESHOLD {
								append(&timeDomainScatters, scatterData)
							} else {
								append(&frequencyDomainScatters, scatterData)
							}
						}
						dataLine := data[(rxBatchStart + receiveChannelIndex + (txBatchStart + transmissionIndex) * receiveChannelCount) * sampleCount:]
						if len(timeDomainScatters) > 0 {
							when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
							convolve_time_domain(sampleCount, timeDomainScatters[:], dataLine)
							when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.convolution, &stageStopwatch)
						}
						if len(frequencyDomainScatters) > 0 {
							when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
							convolve_frequency_domain(sampleCount, frequencyDomainScatters[:], &pffftSetupCache, dataLine)
							when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.convolution, &stageStopwatch)
						}
					}
				}
				completedDatalineScatters += i64(scatterBatchCount) * i64(txBatchEnd - txBatchStart) * i64(batchRxCount)
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
				ekhos_thread.laneSync(lane)
			}
		}
	}

	when CPU_STAGE_TIMING do time.stopwatch_start(&stageStopwatch)
	ekhos_thread.laneSync(lane)
	if ekhos_thread.laneIdx(lane) == 0 {
		apply_temporal_responses(data, sampleCount, 1 / samplingFrequency, transmissions, receiveChannels, impulses, excitations)
	}
	ekhos_thread.laneSync(lane)
	when CPU_STAGE_TIMING do cpu_stage_timing_add(&timing.temporal, &stageStopwatch)
	when CPU_STAGE_TIMING {
		time.stopwatch_stop(&totalStopwatch)
		cpu_stage_timing_max(&sharedTiming.stages.allocation, timing.allocation)
		cpu_stage_timing_max(&sharedTiming.stages.elementResponses, timing.elementResponses)
		cpu_stage_timing_max(&sharedTiming.stages.transmitCoalesce, timing.transmitCoalesce)
		cpu_stage_timing_max(&sharedTiming.stages.receiveCoalesce, timing.receiveCoalesce)
		cpu_stage_timing_max(&sharedTiming.stages.convolution, timing.convolution)
		cpu_stage_timing_max(&sharedTiming.stages.temporal, timing.temporal)
		cpu_stage_timing_max(&sharedTiming.simulation, time.stopwatch_duration(totalStopwatch))
		ekhos_thread.laneSync(lane)
	}
	return
}

CpuScatterData :: struct {
	scatter:                    Scatter,
	transmissionSampleRanges:   []SampleRange,
	receiveChannelSampleRanges: []SampleRange,
	transmissionImpulses:       []f32,
	receiveChannelImpulses:     []f32,
	fftCount:                   i32,
}

coalesce_impulses :: proc(
	elementSets: []$ElementSet,
	batchScatters: []$ScatterData,
	elements: #soa[]RectangularElement,
	elementImpulses: []ImpulseResponse,
	sampleRanges: []SampleRange,
	impulses: []f32,
	sampleCount: i32,
	batchElementSetCount: i32,
	batchElementSetStart: int,
	samplingFrequency, startTime: f32,
	cumulative: bool,
	$applyCumulativeOffset: bool,
) {
	for elementSet, elementSetIndex in elementSets {
		utility.prof_begin("Element Set Impulse")
		for _, scatterIndex in batchScatters {
			scatterElementImpulses := elementImpulses[scatterIndex * auto_cast len(elements):][:len(elements)]
			utility.prof_scoped("Scatterer Impulse")
			utility.prof_begin("Precalculations")
			elementSetSampleRange: SampleRange = {max(i32), min(i32)}
			for element in elementSet.elements {
				elementImpulse := scatterElementImpulses[element.index]
				elementImpulse.rect += element.delay * samplingFrequency

				elementImpulse.scale *= element.apodization
				elementImpulse.rect -= startTime * samplingFrequency
				if applyCumulativeOffset && cumulative do elementImpulse.rect -= 1
				if elementImpulse.scale == 0 do continue
				elementSetSampleRange.minSample = min(elementSetSampleRange.minSample, i32(linalg.floor(elementImpulse.rect.x - 0.5)))
				elementSetSampleRange.maxSample = max(elementSetSampleRange.maxSample, i32(linalg.ceil(elementImpulse.rect.w + 0.5)))
			}
			sampleRanges[scatterIndex * int(batchElementSetCount) + batchElementSetStart + elementSetIndex] = elementSetSampleRange
			elementSetSampleCount := sample_range_sample_count(elementSetSampleRange)
			elementSetImpulse := impulses[(scatterIndex * int(batchElementSetCount) + batchElementSetStart + elementSetIndex) *
			int(sampleCount):][:elementSetSampleCount]
			slice.zero(elementSetImpulse)
			utility.prof_end()
			utility.prof_begin("Sampling")
			for element in elementSet.elements {
				elementImpulse := scatterElementImpulses[element.index]
				elementImpulse.rect += element.delay * samplingFrequency
				elementImpulse.scale *= element.apodization
				elementImpulse.rect -= startTime * samplingFrequency
				if applyCumulativeOffset && cumulative do elementImpulse.rect -= 1
				if elementImpulse.scale == 0 do continue
				elementMinSample := i32(linalg.floor(elementImpulse.rect.x - 0.5))
				elementMaxSample := i32(linalg.ceil(elementImpulse.rect.w + 0.5))
				sample_aperture_add(
					elementSetImpulse[(elementMinSample - elementSetSampleRange.minSample):(elementMaxSample + 1 - elementSetSampleRange.minSample)],
					elementMinSample,
					elementImpulse,
					auto_cast cumulative,
				)
			}
			utility.prof_end()
		}
		utility.prof_end()
	}
}

convolve_time_domain :: proc(sampleCount: i32, scatters: []CpuScatterData, data: []f32) {
	utility.prof_scoped(#procedure)
	#no_bounds_check receiveDataLine := data[:sampleCount]

	utility.prof_begin("Check Sample Range")
	minSample := auto_cast sampleCount
	maxSample: i32 = 0
	for scatterIndex: i32 = 0; scatterIndex < auto_cast len(scatters); scatterIndex += 1 {
		scatterData := scatters[scatterIndex]
		transmissionSampleRange := scatterData.transmissionSampleRanges[0]
		transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
		transmissionMinSample := transmissionSampleRange.minSample
		receiveChannelSampleRange := scatterData.receiveChannelSampleRanges[0]
		receiveChannelSampleCount := sample_range_sample_count(receiveChannelSampleRange)
		receiveChannelMinSample := receiveChannelSampleRange.minSample
		minSample = min(minSample, max(transmissionMinSample + receiveChannelMinSample, 0))
		maxSample = max(
			maxSample,
			min(transmissionMinSample + transmissionSampleCount + receiveChannelMinSample + receiveChannelSampleCount - 1, auto_cast sampleCount),
		)
	}
	utility.prof_end()
	if minSample >= maxSample do return

	for baseSample := minSample; baseSample < maxSample; baseSample += SIMD32_WIDTH {
		samples := baseSample + simd.iota(SIMD_I32)
		sampleMask := simd.lanes_lt(samples, SIMD_I32(maxSample))
		sum := SIMD_F32(0)

		for scatterIndex: i32 = 0; scatterIndex < auto_cast len(scatters); scatterIndex += 1 {
			scatterData := scatters[scatterIndex]
			transmissionSampleRange := scatterData.transmissionSampleRanges[0]
			transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
			receiveChannelSampleRange := scatterData.receiveChannelSampleRanges[0]
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

			transmissionImpulse := scatterData.transmissionImpulses[:transmissionSampleCount]
			receiveChannelImpulse := scatterData.receiveChannelImpulses[:receiveChannelSampleCount]
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

convolve_frequency_domain :: proc(sampleCount: i32, scatters: []CpuScatterData, setupCache: ^map[int]pffft.PffftSession, data: []f32) {
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

	#no_bounds_check receiveDataLine := data[:sampleCount]
	for scatterData in scatters {
		utility.prof_scoped("Scatterer")
		transmissionSampleRange := scatterData.transmissionSampleRanges[0]
		transmissionSampleCount := sample_range_sample_count(transmissionSampleRange)
		receiveChannelSampleRange := scatterData.receiveChannelSampleRanges[0]
		receiveChannelSampleCount := sample_range_sample_count(receiveChannelSampleRange)
		minSample := max(transmissionSampleRange.minSample + receiveChannelSampleRange.minSample, 0)
		maxSample := min(transmissionSampleRange.maxSample + receiveChannelSampleRange.maxSample + 1, sampleCount)
		if minSample >= maxSample do continue

		fftCount := pffft.adjust_n(auto_cast (transmissionSampleCount + receiveChannelSampleCount - 1))
		pffftSession, exists := setupCache^[fftCount]
		if !exists {
			pffftSession = pffft.new_setup(fftCount, .REAL)
			assert(pffftSession != nil)
			map_insert(setupCache, fftCount, pffftSession)
		}

		transmissionImpulse := scatterData.transmissionImpulses[:transmissionSampleCount]
		receiveChannelImpulse := scatterData.receiveChannelImpulses[:receiveChannelSampleCount]
		copy(transmissionFourier[:transmissionSampleCount], transmissionImpulse)
		copy(receiveChannelFourier[:receiveChannelSampleCount], receiveChannelImpulse)
		slice.zero(transmissionFourier[transmissionSampleCount:fftCount])
		slice.zero(receiveChannelFourier[receiveChannelSampleCount:fftCount])
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
		startSample := transmissionSampleRange.minSample + receiveChannelSampleRange.minSample
		for sample := minSample; sample < maxSample; sample += 1 {
			receiveDataLine[sample] += convolutionData[sample - startSample]
		}
	}
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
