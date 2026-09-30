package ekhos

import "core:log"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:slice"
import "core:time"
import utility "ekhos:utility"
import rdoc "import:renderdoc"

@(private = "file")
is_ok :: utility.is_ok
@(private = "file")
confirm :: utility.confirm
@(private = "file")
check :: utility.check
@(private = "file")
assert :: utility.assert
@(private = "file")
assume :: utility.assume

ENABLE_RENDERDOC :: bool(#config(ENABLE_RENDERDOC, true))
PLAN_STAGE_TIMING :: bool(#config(PLAN_STAGE_TIMING, false))

PULSE_CONV_SAMPLE_WORKGROUP_SIZE :: 64
PULSE_CONVOLUTION_TILE_SIZE :: 256

Simulator :: union {
	cpuSimulator,
	vkSimulator,
	hybridSimulator,
}

SimulationSettings :: struct #packed {
	samplingFrequency: f32,
	speedOfSound:      f32,
	startTime:         f32,
	sampleCount:       i32,
	cumulative:        b32,
	cpuSettings:       CpuSettings,
	gpuSettings:       GpuSettings,
	hybridSettings:    HybridSettings,
	metrics:           SimulationMetrics,
}

CpuSettings :: struct {
	threadCount: u32,
}

GpuSettings :: struct {
	backend:                   GpuBackend,
	enableDriverDebugMessages: b32,
}

HybridSettings :: struct {
	cpuScatterFraction: f32,
}

GpuBackend :: enum u32 {
	Vulkan,
}

SimulationMetrics :: struct {
	simulationTime: f32,
}

#assert(size_of(RectangularElement) == 40)
RectangularElement :: struct {
	position:    [3]f32,
	normal:      [3]f32,
	size:        [2]f32,
	apodization: f32,
	delay:       f32,
}

Scatter :: struct {
	position:  [3]f32,
	amplitude: f32,
}
#assert(size_of(Scatter) == 16)

TransducerImpulse :: distinct []f32
Excitation :: TransducerImpulse

// Transducer impulse and excitation use MATLAB-compatible one-based response indices.
// Zero is reserved as the null/identity index; a nonzero index addresses response[index - 1].
Transmission :: struct {
	elements:   #soa[]ElementSetMember,
	impulse:    u16,
	excitation: u16,
}

ReceiveChannel :: struct {
	elements: #soa[]ElementSetMember,
	impulse:  u16,
}

ElementSetMember :: struct {
	index:       i32,
	apodization: f32,
	delay:       f32,
}

DistanceRange :: struct {
	minDistance: f32,
	maxDistance: f32,
}

SampleRange :: struct {
	minSample: i32,
	maxSample: i32,
}

ImpulseResponse :: struct {
	rect:  [4]f32,
	scale: f32,
}

simulate :: proc(
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
	impulses: []TransducerImpulse,
	excitations: []Excitation,
	allocator := context.allocator,
) -> (
	data: []f32,
	ok := true,
) {
	utility.prof_scoped(#procedure)

	switch &sim in simulator {
	case cpuSimulator:
	case vkSimulator:
		assert(settings.gpuSettings.backend == .Vulkan, "Only the Vulkan GPU backend is implemented")
	case hybridSimulator:
		assert(settings.gpuSettings.backend == .Vulkan, "Only the Vulkan GPU backend is implemented")
	}

	stopwatch: time.Stopwatch
	time.stopwatch_start(&stopwatch)
	switch &sim in simulator {
	case vkSimulator:
		when ENABLE_RENDERDOC {
			if sim.rdocApi != nil {
				rdoc.start_frame_capture(sim.rdocApi, nil, nil)
				assert(rdoc.is_frame_capturing(sim.rdocApi))
			}
			defer if sim.rdocApi != nil {
				captureOk := rdoc.end_frame_capture(sim.rdocApi, nil, nil)
				if !captureOk do log.error("renderdoc: EndFrameCapture failed")
				launch_or_show_renderdoc_ui(sim.rdocApi)
			}
		}

		data = is_ok(check(simulate_vulkan(&sim, settings^, transmissions, receiveChannels, elements, scatters, impulses, excitations))) or_return
	case cpuSimulator:
		data = check(simulate_cpu(&sim, settings^, transmissions, receiveChannels, elements, scatters, impulses, excitations)) or_return
	case hybridSimulator:
		data, ok = simulate_hybrid(&sim, settings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
	}
	time.stopwatch_stop(&stopwatch)
	settings.metrics.simulationTime = auto_cast time.duration_seconds(time.stopwatch_duration(stopwatch))

	return
}

plan_simulation :: proc(
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
	impulses: []TransducerImpulse,
	excitations: []Excitation,
) -> (
	ok := true,
) {
	utility.prof_scoped(#procedure)
	when PLAN_STAGE_TIMING {
		planStopwatch: time.Stopwatch
		time.stopwatch_start(&planStopwatch)
		defer {
			time.stopwatch_stop(&planStopwatch)
			planningDuration := time.stopwatch_duration(planStopwatch)
			#partial switch &sim in simulator {
			case cpuSimulator:
				sim.timing.planning = planningDuration
			case vkSimulator:
				sim.timing.planning = planningDuration
			}
		}
	}
	switch &sim in simulator {
	case cpuSimulator:
	case vkSimulator:
		assert(settings.gpuSettings.backend == .Vulkan, "Only the Vulkan GPU backend is implemented")
	case hybridSimulator:
		assert(settings.gpuSettings.backend == .Vulkan, "Only the Vulkan GPU backend is implemented")
	}
	normalize_element_normals(elements)
	for transmission in transmissions {
		for element in transmission.elements {
			check(element.index >= 0 && element.index < i32(len(elements)))
		}
	}
	for receiveChannel in receiveChannels {
		for element in receiveChannel.elements {
			assert(element.index >= 0 && element.index < i32(len(elements)))
		}
	}
	for transmission in transmissions {
		assert(transmission.impulse == 0 || int(transmission.impulse) <= len(impulses))
		assert(transmission.excitation == 0 || int(transmission.excitation) <= len(excitations))
	}
	for receiveChannel in receiveChannels {
		assert(receiveChannel.impulse == 0 || int(receiveChannel.impulse) <= len(impulses))
	}

	distanceRange, apertureSampleCount := sort_scatters_by_distance_interval(scatters, transmissions, receiveChannels, elements, settings^)
	settings.startTime = distanceRange.minDistance / settings.speedOfSound
	sampleRange := distance_range_to_sample_range(distanceRange, settings.speedOfSound, settings.samplingFrequency, settings.startTime)
	settings.sampleCount = sample_range_sample_count(sampleRange)
	sampleCountPadding :: 6
	settings.sampleCount += sampleCountPadding
	settings.startTime -= sampleCountPadding / 4 / settings.samplingFrequency

	maxTemporalTail: i32
	for transmission in transmissions {
		transmissionLength := response_length(impulses, transmission.impulse) + response_length(excitations, transmission.excitation) - 1
		for receiveChannel in receiveChannels {
			receiveLength := response_length(impulses, receiveChannel.impulse)
			maxTemporalTail = max(maxTemporalTail, transmissionLength + receiveLength - 2)
		}
	}
	settings.sampleCount += maxTemporalTail

	// We are rounding up to the nearest multiple of 32
	// PFFFT requires this for the CPU simulator, and it avoids some potential warp divergence on the GPU
	settings.sampleCount = (settings.sampleCount + 31) & ~i32(31)

	scattererBatchSize: u32 = max(u32(1), min(u32(len(scatters)), u32(256)))

	switch &sim in simulator {
	case vkSimulator:
		sim.info.apertureSampleCount = apertureSampleCount
		sim.info.scattererBatchSize = scattererBatchSize
		is_ok(check(plan_vulkan_simulator(&sim, settings^, transmissions, receiveChannels, elements, scatters, impulses, excitations))) or_return
	case cpuSimulator:
		sim.info.apertureSampleCount = apertureSampleCount
		sim.info.scattererBatchSize = scattererBatchSize
		check(plan_cpu_simulation(&sim, settings)) or_return
	case hybridSimulator:
		assert(
			settings.hybridSettings.cpuScatterFraction >= 0 && settings.hybridSettings.cpuScatterFraction <= 1,
			"Hybrid CPU scatter fraction must be in [0, 1]",
		)
		sim.cpu.info.apertureSampleCount = apertureSampleCount
		sim.cpu.info.scattererBatchSize = scattererBatchSize
		sim.gpu.info.apertureSampleCount = apertureSampleCount
		sim.gpu.info.scattererBatchSize = scattererBatchSize
		check(plan_cpu_simulation(&sim.cpu, settings)) or_return
		is_ok(check(plan_vulkan_simulator(&sim.gpu, settings^, transmissions, receiveChannels, elements, scatters, impulses, excitations))) or_return
	}
	return
}

log_simulation_timing :: proc(simulator: ^Simulator, label: string, loc := #caller_location) {
	#partial switch &sim in simulator {
	case cpuSimulator:
		log_cpu_timing(sim.timing, label, loc)
	case vkSimulator:
		log_gpu_timing(sim.timing, label, loc)
	case hybridSimulator:
		log_cpu_timing(sim.cpu.timing, label, loc)
		log_gpu_timing(sim.gpu.timing, label, loc)
	}
}

response_length :: proc(responses: $T, index: u16) -> i32 {
	if index == 0 do return 1
	response := responses[int(index) - 1]
	return max(i32(1), i32(len(response)))
}

normalize_element_normals :: proc(elements: #soa[]RectangularElement) {
	for elementIndex in 0 ..< len(elements) {
		normal := elements.normal[elementIndex]
		normalLength := linalg.length(normal)
		assert(normalLength > linalg.F32_EPSILON, "Element normal must have non-zero length")
		elements.normal[elementIndex] = normal / normalLength
	}
}

calculate_array_centroid :: proc(elements: #soa[]RectangularElement) -> [3]f32 {
	if len(elements) == 0 do return {0, 0, 0}
	sum: [3]f32 = {0, 0, 0}
	for i in 0 ..< len(elements) {
		sum += elements[i].position
	}
	return sum / f32(len(elements))
}

sort_scatters_by_centroid_distance :: proc(scatters: []Scatter, centroid: [3]f32) {
	if len(scatters) <= 1 do return
	c := centroid
	slice.sort_by_with_data(scatters, proc(a, b: Scatter, user_data: rawptr) -> bool {
			centroid_ptr := (^[3]f32)(user_data)
			da := linalg.length2(a.position - centroid_ptr^)
			db := linalg.length2(b.position - centroid_ptr^)
			return da < db
		}, &c)
}

DistanceBounds :: struct {
	minimum: [3]f32,
	maximum: [3]f32,
}

DEFAULT_DISTANCE_BOUNDS: DistanceBounds : {minimum = {math.INF_F32, math.INF_F32, math.INF_F32}, maximum = {-math.INF_F32, -math.INF_F32, -math.INF_F32}}

DistanceRepresentatives :: struct {
	transmit: [8][3]f32,
	receive:  [8][3]f32,
}

sort_scatters_by_distance_interval :: proc(
	scatters: []Scatter,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	settings: SimulationSettings,
) -> (
	distanceRange: DistanceRange,
	apertureSampleCount: u32,
) {
	utility.prof_scoped(#procedure)
	defer assert(distanceRange.maxDistance - distanceRange.minDistance >= 0)
	// Any distance range greater than 10m is likely an error, and furthermore would require an unreasonable amount of memory
	defer assert(distanceRange.maxDistance - distanceRange.minDistance < 10)

	transmitBounds := DEFAULT_DISTANCE_BOUNDS
	for transmission in transmissions {
		for transmissionElement in transmission.elements {
			distance_bounds_add_element(&transmitBounds, elements[transmissionElement.index])
		}
	}
	receiveBounds := DEFAULT_DISTANCE_BOUNDS
	for receiveChannel in receiveChannels {
		for receiveChannelElement in receiveChannel.elements {
			distance_bounds_add_element(&receiveBounds, elements[receiveChannelElement.index])
		}
	}

	representatives := DistanceRepresentatives{}
	distance_bounds_make_representatives(transmitBounds, &representatives.transmit)
	distance_bounds_make_representatives(receiveBounds, &representatives.receive)

	minTransmitDistance, maxTransmitDistance: f32 = math.INF_F32, 0
	minReceiveDistance, maxReceiveDistance: f32 = math.INF_F32, 0
	distanceMidpoints := make([]f32, len(scatters), context.allocator)
	defer delete(distanceMidpoints)
	for scatterIndex in 0 ..< len(scatters) {
		scatter := scatters[scatterIndex]
		transmitMinimum: f32 = math.INF_F32
		transmitMaximum: f32 = 0
		for representative in representatives.transmit {
			distance := linalg.length(scatter.position - representative)
			transmitMinimum = min(transmitMinimum, distance)
			transmitMaximum = max(transmitMaximum, distance)
		}

		receiveMinimum: f32 = math.INF_F32
		receiveMaximum: f32 = 0
		for representative in representatives.receive {
			distance := linalg.length(scatter.position - representative)
			receiveMinimum = min(receiveMinimum, distance)
			receiveMaximum = max(receiveMaximum, distance)
		}

		minTransmitDistance = min(minTransmitDistance, transmitMinimum)
		maxTransmitDistance = max(maxTransmitDistance, transmitMaximum)
		minReceiveDistance = min(minReceiveDistance, receiveMinimum)
		maxReceiveDistance = max(maxReceiveDistance, receiveMaximum)
		distanceMidpoints[scatterIndex] = (transmitMinimum + transmitMaximum + receiveMinimum + receiveMaximum) / 2
	}

	if len(scatters) > 1 {
		indices := slice.sort_with_indices(distanceMidpoints, context.allocator)
		defer delete(indices)
		slice.sort_from_permutation_indices(scatters, indices)
	}

	distanceRange = {minTransmitDistance + minReceiveDistance, maxTransmitDistance + maxReceiveDistance}
	transmitSampleRange := distance_range_to_sample_range({minTransmitDistance, maxTransmitDistance}, settings.speedOfSound, settings.samplingFrequency, 0)
	receiveSampleRange := distance_range_to_sample_range({minReceiveDistance, maxReceiveDistance}, settings.speedOfSound, settings.samplingFrequency, 0)
	apertureSampleCount = u32(max(sample_range_sample_count(transmitSampleRange), sample_range_sample_count(receiveSampleRange))) + 1
	return
}

distance_bounds_add :: proc(bounds: ^DistanceBounds, position: [3]f32) {
	bounds.minimum = linalg.min(bounds.minimum, position)
	bounds.maximum = linalg.max(bounds.maximum, position)
}

distance_bounds_add_element :: proc(bounds: ^DistanceBounds, element: RectangularElement) {
	elementExtent := linalg.length(element.size) / 2
	distance_bounds_add(bounds, element.position - elementExtent)
	distance_bounds_add(bounds, element.position + elementExtent)
}

distance_bounds_make_representatives :: proc(bounds: DistanceBounds, representatives: ^[8][3]f32) {
	for corner in 0 ..< 8 {
		representatives[corner] = [3]f32 {
			((corner >> 0) & 1) == 0 ? bounds.minimum.x : bounds.maximum.x,
			((corner >> 1) & 1) == 0 ? bounds.minimum.y : bounds.maximum.y,
			((corner >> 2) & 1) == 0 ? bounds.minimum.z : bounds.maximum.z,
		}
	}
}

MortonSortData :: struct {
	minimum: [3]f32,
	maximum: [3]f32,
}

sort_scatters_by_morton_code :: proc(scatters: []Scatter) {
	if len(scatters) <= 1 do return

	sortData := MortonSortData {
		minimum = scatters[0].position,
		maximum = scatters[0].position,
	}
	for scatter in scatters[1:] {
		for axis in 0 ..< 3 {
			sortData.minimum[axis] = min(sortData.minimum[axis], scatter.position[axis])
			sortData.maximum[axis] = max(sortData.maximum[axis], scatter.position[axis])
		}
	}

	codes := make([]u32, len(scatters), context.allocator)
	defer delete(codes)
	for i in 0 ..< len(scatters) {
		codes[i] = scatter_morton_code(scatters[i].position, sortData.minimum, sortData.maximum)
	}

	indices := slice.sort_with_indices(codes, context.allocator)
	defer delete(indices)
	slice.sort_from_permutation_indices(scatters, indices)
}

scatter_morton_code :: proc(position, minimum, maximum: [3]f32) -> u32 {
	MortonAxisBits: uint : 10
	coordinates := quantize_scatter_position(position, minimum, maximum, MortonAxisBits)

	result: u32
	for bit_index in 0 ..< MortonAxisBits {
		for axis in 0 ..< 3 {
			source_bit := bits.bitfield_extract(coordinates[axis], bit_index, uint(1))
			destination_bit := bit_index * 3 + auto_cast axis
			result = bits.bitfield_insert(result, source_bit, destination_bit, uint(1))
		}
	}
	return result
}

sort_scatters_by_hilbert_code :: proc(scatters: []Scatter) {
	if len(scatters) <= 1 do return

	sortData := MortonSortData {
		minimum = scatters[0].position,
		maximum = scatters[0].position,
	}
	for scatter in scatters[1:] {
		for axis in 0 ..< 3 {
			sortData.minimum[axis] = min(sortData.minimum[axis], scatter.position[axis])
			sortData.maximum[axis] = max(sortData.maximum[axis], scatter.position[axis])
		}
	}

	codes := make([]u32, len(scatters), context.allocator)
	defer delete(codes)
	for i in 0 ..< len(scatters) {
		codes[i] = scatter_hilbert_code(scatters[i].position, sortData.minimum, sortData.maximum)
	}

	indices := slice.sort_with_indices(codes, context.allocator)
	defer delete(indices)
	slice.sort_from_permutation_indices(scatters, indices)
}

sort_scatters_by_depth_banded_morton :: proc(scatters: []Scatter, depthBandCount: u32) {
	if len(scatters) <= 1 do return

	sortData := MortonSortData {
		minimum = scatters[0].position,
		maximum = scatters[0].position,
	}
	for scatter in scatters[1:] {
		for axis in 0 ..< 3 {
			sortData.minimum[axis] = min(sortData.minimum[axis], scatter.position[axis])
			sortData.maximum[axis] = max(sortData.maximum[axis], scatter.position[axis])
		}
	}

	codes := make([]u32, len(scatters), context.allocator)
	defer delete(codes)
	for scatterIndex in 0 ..< len(scatters) {
		coordinates := quantize_scatter_position(scatters[scatterIndex].position, sortData.minimum, sortData.maximum, 10)
		depthBand := min(depthBandCount - 1, coordinates.z * depthBandCount / 1024)
		xyCode := scatter_morton_2d_code(coordinates.x, coordinates.y)
		codes[scatterIndex] = (depthBand << 20) | xyCode
	}

	indices := slice.sort_with_indices(codes, context.allocator)
	defer delete(indices)
	slice.sort_from_permutation_indices(scatters, indices)
}

scatter_morton_2d_code :: proc(x, y: u32) -> u32 {
	result: u32
	for bitIndex in 0 ..< 10 {
		bit := uint(bitIndex)
		result = bits.bitfield_insert(result, bits.bitfield_extract(x, bit, uint(1)), bit * 2, uint(1))
		result = bits.bitfield_insert(result, bits.bitfield_extract(y, bit, uint(1)), bit * 2 + 1, uint(1))
	}
	return result
}

quantize_scatter_position :: proc(position, minimum, maximum: [3]f32, axisBits: uint) -> [3]u32 {
	axisMax: f32 = f32((u32(1) << axisBits) - 1)
	coordinates: [3]u32
	for axis in 0 ..< 3 {
		span := maximum[axis] - minimum[axis]
		normalized: f32 = 0
		if span > 0 {
			normalized = (position[axis] - minimum[axis]) / span
		}
		normalized = min(1, max(0, normalized))
		coordinates[axis] = u32(normalized * axisMax + 0.5)
	}
	return coordinates
}

scatter_hilbert_code :: proc(position, minimum, maximum: [3]f32) -> u32 {
	HilbertAxisBits: uint : 10
	coordinates := quantize_scatter_position(position, minimum, maximum, HilbertAxisBits)

	// Skilling's transpose algorithm converts 3D coordinates into Hilbert distance.
	mostSignificantBit := u32(1) << (HilbertAxisBits - 1)
	q := mostSignificantBit
	for q > 1 {
		p := q - 1
		for axis in 0 ..< 3 {
			if (coordinates[axis] & q) != 0 {
				coordinates[0] ~= p
			} else {
				t := (coordinates[0] ~ coordinates[axis]) & p
				coordinates[0] ~= t
				coordinates[axis] ~= t
			}
		}
		q >>= 1
	}

	for axis in 1 ..< 3 {
		coordinates[axis] ~= coordinates[axis - 1]
	}

	transform: u32
	q = mostSignificantBit
	for q > 1 {
		if (coordinates[2] & q) != 0 {
			transform ~= q - 1
		}
		q >>= 1
	}
	for axis in 0 ..< 3 {
		coordinates[axis] ~= transform
	}

	result: u32
	bitIndex := int(HilbertAxisBits)
	for bitIndex > 0 {
		bitIndex -= 1
		for axis in 0 ..< 3 {
			result = (result << 1) | ((coordinates[axis] >> u32(bitIndex)) & 1)
		}
	}
	return result
}

launch_or_show_renderdoc_ui :: proc(rdoc_api: rdoc.Api) {
	num_captures, num_ok := rdoc.get_num_captures(rdoc_api)
	if !num_ok || num_captures == 0 do return
	latest_capture_index := num_captures - 1

	abs_capture_path, timestamp, cap_ok := rdoc.get_capture_info(rdoc_api, latest_capture_index, context.temp_allocator)
	if cap_ok {
		log.infof("loading latest capture (%v): %v", timestamp, abs_capture_path)
		pid, ok := rdoc.launch_or_show_replay_ui(rdoc_api, abs_capture_path)
		if !ok {
			log.error("couldn't launch or show Renderdoc UI")
			return
		}
		if pid != 0 {
			log.infof("launched Renderdoc UI pid(%v)", pid)
		}
	} else {
		log.warnf("no valid capture exists to load")
	}
}

sample_range_sample_count :: proc(range: SampleRange) -> i32 {
	return range.maxSample - range.minSample + 1
}

distance_range_to_sample_range :: proc(range: DistanceRange, speedOfSound, samplingFrequency, startTime: f32) -> SampleRange {
	return {
		cast(i32)math.floor(((range.minDistance / speedOfSound) - startTime) * samplingFrequency),
		cast(i32)math.ceil(((range.maxDistance / speedOfSound) - startTime) * samplingFrequency),
	}
}

sample_range_from_impulse :: #force_no_inline proc(impulse: ImpulseResponse) -> SampleRange {
	return impulse.scale == 0 ? {0, 0} : {i32(linalg.floor(impulse.rect.x - 0.5)), i32(linalg.ceil(impulse.rect.w + 0.5))}
}
