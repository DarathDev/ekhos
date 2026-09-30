package ekhos_scripts

import "core:log"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:testing"
import ekhos "ekhos:."
import utility "ekhos:utility"

check :: utility.check
is_ok :: utility.is_ok

CUMULATIVE :: bool(#config(TEST_CUMULATIVE, true))
RUN_SIMULATION :: bool(#config(TEST_RUN_SIMULATION, true))
BENCHMARK :: bool(#config(BENCHMARK, false))
BENCHMARK_SCATTER_MULTIPLIER :: int(#config(BENCHMARK_SCATTER_MULTIPLIER, 1))
LINEAR_SCATTER_COUNT :: int(#config(TEST_LINEAR_SCATTER_COUNT, 16))
MATRIX_SCATTER_COUNT :: int(#config(TEST_MATRIX_SCATTER_COUNT, 64))
BENCHMARK_ITERATIONS :: 5
RUN_ONE_RECT :: bool(#config(TEST_RUN_ONE_RECT, true))
RUN_LINEAR :: bool(#config(TEST_RUN_LINEAR, true))
RUN_MATRIX :: bool(#config(TEST_RUN_MATRIX, true))
MIN_CORRELATION :: 0.95
MAX_RMS_ERROR_PERCENT :: 1
MAX_RELATIVE_DIFFERENCE_PERCENT :: 5
BENCHMARK_HYBRID_CPU_FRACTIONS :: []f32{0.25, 0.5, 0.75}

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	if RUN_ONE_RECT do oneRectSimulation()
	if RUN_LINEAR do linearArraySimulation()
	if RUN_MATRIX do matrixArraySimulation()
}

@(test)
oneRectSimulationTest :: proc(t: ^testing.T) {
	if !RUN_ONE_RECT do return
	_ = utility.expect(t, oneRectSimulation())
}

@(test)
linearArraySimulationTest :: proc(t: ^testing.T) {
	if !RUN_LINEAR do return
	_ = utility.expect(t, linearArraySimulation())
}

@(test)
matrixArraySimulationTest :: proc(t: ^testing.T) {
	if !RUN_MATRIX do return
	_ = utility.expect(t, matrixArraySimulation())
}

@(test)
temporalResponseTest :: proc(t: ^testing.T) {
	input := []f32{1, 2, 3, 0, 0, 0, 0, 0}
	impulses := []ekhos.TransducerImpulse{{1, 2}, {1, -1}}
	excitations := []ekhos.Excitation{{0.5, 1}}
	transmissions := []ekhos.Transmission{{impulse = 1, excitation = 1}}
	receiveChannels := []ekhos.ReceiveChannel{{impulse = 2}}

	ekhos.apply_temporal_responses(input, i32(len(input)), 1, transmissions, receiveChannels, impulses, excitations)
	expected := []f32{0.5, 2.5, 4.5, 2.5, -4.0, -6.0, 0.0, 0.0}
	passed := true
	for actual, index in input {
		expectedValue := expected[index]
		if math.abs(actual - expectedValue) > f32(1e-6) {
			passed = false
		}
	}
	_ = utility.expect(t, passed)
}

compare_simulation_outputs :: proc(label: string, reference, actual: []f32) -> (ok := true) {
	if len(reference) != len(actual) {
		log.errorf("%s output length mismatch: %d != %d", label, len(reference), len(actual))
		return false
	}

	maxDifference: f32
	sumSquaredDifference: f64
	sumSquaredReference: f64
	sumSquaredActual: f64
	dotProduct: f64
	referencePeak: f32
	actualPeak: f32
	for i in 0 ..< len(reference) {
		referenceValue := reference[i]
		actualValue := actual[i]
		referenceAbs := math.abs(referenceValue)
		actualAbs := math.abs(actualValue)
		if referenceAbs > referencePeak do referencePeak = referenceAbs
		if actualAbs > actualPeak do actualPeak = actualAbs

		difference := referenceValue - actualValue
		sumSquaredDifference += f64(difference) * f64(difference)
		sumSquaredReference += f64(referenceValue) * f64(referenceValue)
		sumSquaredActual += f64(actualValue) * f64(actualValue)
		dotProduct += f64(referenceValue) * f64(actualValue)
		maxDifference = max(maxDifference, math.abs(difference))
	}

	normReference := math.sqrt(sumSquaredReference)
	normActual := math.sqrt(sumSquaredActual)
	normDifference := math.sqrt(sumSquaredDifference)
	correlation := (normReference > 0 && normActual > 0) ? f32(dotProduct / (normReference * normActual)) : 0.0
	energyRatio := sumSquaredReference > 0 ? f32(sumSquaredDifference / sumSquaredReference) : 0.0
	peakRatio := referencePeak > 0 ? actualPeak / referencePeak : (actualPeak == 0 ? 1.0 : 0.0)
	rmsErrorPercent := sumSquaredReference > 0 ? f32((normDifference / normReference) * 100.0) : 0.0
	maxRelativeDifferencePercent := referencePeak > 0 ? (maxDifference / referencePeak) * 100.0 : 0.0

	log.infof(
		"%s signal metrics: samples=%d maxRelDiff=%.2f%% RMS=%.2f%% corr=%.6f peakRatio=%.4f energyRatio=%.4e",
		label,
		len(reference),
		maxRelativeDifferencePercent,
		rmsErrorPercent,
		correlation,
		peakRatio,
		energyRatio,
	)
	return correlation >= MIN_CORRELATION && rmsErrorPercent <= MAX_RMS_ERROR_PERCENT && maxRelativeDifferencePercent <= MAX_RELATIVE_DIFFERENCE_PERCENT
}

compare_simulators :: proc(
	settings: ekhos.SimulationSettings,
	transmissions: []ekhos.Transmission,
	receiveChannels: []ekhos.ReceiveChannel,
	elements: #soa[]ekhos.RectangularElement,
	scatters: []ekhos.Scatter,
	impulses: []ekhos.TransducerImpulse,
	excitations: []ekhos.Excitation,
) -> (
	ok := true,
) {
	cpuSettings := settings
	gpuSettings := settings
	hybridSettings := settings
	hybridSettings.hybridSettings.cpuScatterFraction = 0.5

	cpuSimulator, cpuOk := ekhos.create_cpu_simulator()
	if !cpuOk do return false
	cpuSim: ekhos.Simulator = cpuSimulator
	defer ekhos.destroy_cpu_simulator(&cpuSim.(ekhos.cpuSimulator))

	gpuSimulator, gpuResult := ekhos.create_vulkan_simulator(gpuSettings)
	if gpuResult != .SUCCESS do return false

	gpuSim: ekhos.Simulator = gpuSimulator
	defer ekhos.destroy_vulkan_simulator(&gpuSim.(ekhos.vkSimulator))

	hybridSimulator, hybridOk := ekhos.create_hybrid_simulator(hybridSettings)
	if !hybridOk do return false
	hybridSim: ekhos.Simulator = hybridSimulator
	defer ekhos.destroy_hybrid_simulator(&hybridSim.(ekhos.hybridSimulator))

	if !ekhos.plan_simulation(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations) do return false
	if !ekhos.plan_simulation(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations) do return false
	if !ekhos.plan_simulation(&hybridSim, &hybridSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations) do return false
	if !RUN_SIMULATION do return true

	if BENCHMARK {
		cpuWarmup, cpuWarmupOk := ekhos.simulate(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
		if !cpuWarmupOk do return false
		delete(cpuWarmup)
		gpuWarmup, gpuWarmupOk := ekhos.simulate(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
		if !gpuWarmupOk do return false
		delete(gpuWarmup)

		cpuTotal: f64
		gpuTotal: f64
		cpuMinimum: f32 = 3.4028235e38
		gpuMinimum: f32 = 3.4028235e38
		for _ in 0 ..< BENCHMARK_ITERATIONS {
			cpuData, cpuSimulationOk := ekhos.simulate(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
			if !cpuSimulationOk do return false
			gpuData, gpuSimulationOk := ekhos.simulate(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
			if !gpuSimulationOk do return false

			cpuTime := cpuSettings.metrics.simulationTime
			gpuTime := gpuSettings.metrics.simulationTime
			cpuTotal += f64(cpuTime)
			gpuTotal += f64(gpuTime)
			cpuMinimum = min(cpuMinimum, cpuTime)
			gpuMinimum = min(gpuMinimum, gpuTime)
			delete(cpuData)
			delete(gpuData)
		}
		cpuAverage := f32(cpuTotal / f64(BENCHMARK_ITERATIONS))
		gpuAverage := f32(gpuTotal / f64(BENCHMARK_ITERATIONS))
		log.infof(
			"CPU/GPU benchmark: elements=%d scatters=%d transmissions=%d receiveChannels=%d iterations=%d cpuAvg=%.6fs gpuAvg=%.6fs cpuMin=%.6fs gpuMin=%.6fs gpuSpeedup=%.3fx",
			len(elements),
			len(scatters),
			len(transmissions),
			len(receiveChannels),
			BENCHMARK_ITERATIONS,
			cpuAverage,
			gpuAverage,
			cpuMinimum,
			gpuMinimum,
			gpuAverage > 0 ? cpuAverage / gpuAverage : 0,
		)

		for cpuScatterFraction in BENCHMARK_HYBRID_CPU_FRACTIONS {
			hybridFractionSettings := hybridSettings
			hybridFractionSettings.hybridSettings.cpuScatterFraction = cpuScatterFraction
			hybridFractionSimulator, hybridFractionOk := ekhos.create_hybrid_simulator(hybridFractionSettings)
			if !hybridFractionOk do return false
			hybridFractionSim: ekhos.Simulator = hybridFractionSimulator
			if !ekhos.plan_simulation(&hybridFractionSim, &hybridFractionSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations) {
				ekhos.destroy_hybrid_simulator(&hybridFractionSim.(ekhos.hybridSimulator))
				return false
			}

			hybridWarmup, hybridWarmupOk := ekhos.simulate(
				&hybridFractionSim,
				&hybridFractionSettings,
				transmissions,
				receiveChannels,
				elements,
				scatters,
				impulses,
				excitations,
			)
			if !hybridWarmupOk {
				ekhos.destroy_hybrid_simulator(&hybridFractionSim.(ekhos.hybridSimulator))
				return false
			}
			delete(hybridWarmup)

			hybridTotal: f64
			hybridMinimum: f32 = 3.4028235e38
			for _ in 0 ..< BENCHMARK_ITERATIONS {
				hybridData, hybridSimulationOk := ekhos.simulate(
					&hybridFractionSim,
					&hybridFractionSettings,
					transmissions,
					receiveChannels,
					elements,
					scatters,
					impulses,
					excitations,
				)
				if !hybridSimulationOk {
					ekhos.destroy_hybrid_simulator(&hybridFractionSim.(ekhos.hybridSimulator))
					return false
				}
				hybridTime := hybridFractionSettings.metrics.simulationTime
				hybridTotal += f64(hybridTime)
				hybridMinimum = min(hybridMinimum, hybridTime)
				delete(hybridData)
			}

			hybridAverage := f32(hybridTotal / f64(BENCHMARK_ITERATIONS))
			log.infof(
				"Hybrid benchmark: cpuCores=%d cpuScatterFraction=%.2f elements=%d scatters=%d iterations=%d average=%.6fs minimum=%.6fs cpuSpeedup=%.3fx",
				os.get_processor_core_count(),
				cpuScatterFraction,
				len(elements),
				len(scatters),
				BENCHMARK_ITERATIONS,
				hybridAverage,
				hybridMinimum,
				hybridAverage > 0 ? cpuAverage / hybridAverage : 0,
			)
			ekhos.destroy_hybrid_simulator(&hybridFractionSim.(ekhos.hybridSimulator))
		}
	}

	cpuData, cpuSimulationOk := ekhos.simulate(&cpuSim, &cpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
	if !cpuSimulationOk do return false
	defer delete(cpuData)
	gpuData, gpuSimulationOk := ekhos.simulate(&gpuSim, &gpuSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
	if !gpuSimulationOk do return false
	defer delete(gpuData)
	hybridData, hybridSimulationOk := ekhos.simulate(&hybridSim, &hybridSettings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
	if !hybridSimulationOk do return false
	defer delete(hybridData)

	return compare_simulation_outputs("CPU/GPU", cpuData, gpuData) && compare_simulation_outputs("CPU/Hybrid", cpuData, hybridData)
}

oneRectSimulation :: proc() -> (ok := true) {

	utility.prof_init("oneRectSimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	settings := ekhos.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = auto_cast CUMULATIVE,
		cpuSettings = {threadCount = 1},
		gpuSettings = {enableDriverDebugMessages = auto_cast (utility.PROF_MODE == .None && !BENCHMARK)},
	}

	transmitElement: ekhos.RectangularElement = {
		position    = {0, 0, 0},
		normal      = {0, 0, 1},
		size        = {2.2e-4, 2.2e-4},
		apodization = 1,
	}

	receiveElement: ekhos.RectangularElement = {
		position    = {0, 0, 0},
		normal      = {0, 0, 1},
		size        = {2.2e-4, 2.2e-4},
		apodization = 1,
	}

	scatter: ekhos.Scatter = {
		position  = {-6.164e-3, 7.192e-3, 50.492e-3},
		amplitude = 1,
	}

	elements := make(#soa[]ekhos.RectangularElement, 1, context.allocator)
	defer delete(elements)
	elements[0] = transmitElement
	elements[0].apodization = receiveElement.apodization

	transmissionElements := make(#soa[]ekhos.ElementSetMember, 1, context.allocator)
	defer delete(transmissionElements)
	transmissionElements[0] = {
		index       = 0,
		apodization = 1,
		delay       = 0,
	}
	receiveChannelElements := make(#soa[]ekhos.ElementSetMember, 1, context.allocator)
	defer delete(receiveChannelElements)
	receiveChannelElements[0] = ekhos.ElementSetMember {
		index       = 0,
		apodization = 1,
		delay       = 0,
	}

	transmissions := make([]ekhos.Transmission, 1, context.allocator)
	defer delete(transmissions)
	transmissions[0] = {
		elements = transmissionElements,
	}
	receiveChannels := make([]ekhos.ReceiveChannel, 1, context.allocator)
	defer delete(receiveChannels)
	receiveChannels[0] = {
		elements = receiveChannelElements,
	}
	scatters := slice.from_ptr(&scatter, 1)

	impulses := []ekhos.TransducerImpulse{{1, 2}, {1, -1}}
	excitations := []ekhos.Excitation{{0.5, 1}}
	transmissions[0].impulse = 1
	transmissions[0].excitation = 1
	receiveChannels[0].impulse = 2
	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
}

linearArraySimulation :: proc() -> (ok := true) {

	utility.prof_init("linearArraySimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	scatterCount := LINEAR_SCATTER_COUNT * BENCHMARK_SCATTER_MULTIPLIER
	rowCount :: 1
	columnCount :: 128
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	settings := ekhos.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = auto_cast CUMULATIVE,
		cpuSettings = {threadCount = 1},
		gpuSettings = {enableDriverDebugMessages = auto_cast (utility.PROF_MODE == .None && !BENCHMARK)},
	}

	elements := make_transmit_and_receive_grid_elements(columnCount, rowCount, elementPitch, elementWidth, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(columnCount * rowCount)
	receiveChannels := make_column_receive_channels(columnCount, rowCount, len(transmissions[0].elements))
	defer {
		for receiveChannel in receiveChannels do delete(receiveChannel.elements)
		delete(receiveChannels)
		delete(transmissions[0].elements)
		delete(transmissions)
	}
	scatters := make_random_scatters(scatterCount, {-8e-3, 8e-3}, {-8e-3, 8e-3}, {10e-3, 100e-3})
	defer delete(scatters)

	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters, nil, nil)
}

matrixArraySimulation :: proc() -> (ok := true) {

	utility.prof_init("matrixArraySimulation")
	utility.prof_thread_init()
	utility.prof_scoped(#procedure)

	scatterCount := MATRIX_SCATTER_COUNT * BENCHMARK_SCATTER_MULTIPLIER
	rowCount :: 32
	columnCount :: 32
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	settings := ekhos.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = auto_cast CUMULATIVE,
		cpuSettings = {threadCount = 1},
		gpuSettings = {enableDriverDebugMessages = auto_cast (utility.PROF_MODE == .None && !BENCHMARK)},
	}

	elements := make_transmit_and_receive_grid_elements(columnCount, rowCount, elementPitch * [2]f32{1, 1}, elementWidth * [2]f32{1, 1}, 0)
	defer delete(elements)
	transmissions := make_full_aperture_transmissions(columnCount * rowCount)
	receiveChannels := make_single_element_receive_channels(columnCount * rowCount, len(transmissions[0].elements))
	defer {
		for receiveChannel in receiveChannels do delete(receiveChannel.elements)
		delete(receiveChannels)
		delete(transmissions[0].elements)
		delete(transmissions)
	}
	scatters := make_random_scatters(scatterCount, {-8e-3, 8e-3}, {-8e-3, 8e-3}, {0, 100e-3})
	defer delete(scatters)

	return compare_simulators(settings, transmissions, receiveChannels, elements, scatters, nil, nil)
}

make_random_scatters :: proc(count: int, xRange, yRange, zRange: [2]f32) -> []ekhos.Scatter {
	scatters := make([]ekhos.Scatter, count, context.allocator)
	for i in 0 ..< count {
		x := rand.float32_range(xRange[0], xRange[1])
		y := rand.float32_range(yRange[0], yRange[1])
		z := rand.float32_range(zRange[0], zRange[1])
		scatters[i] = {
			position  = {x, y, z},
			amplitude = 1,
		}
	}
	return scatters
}

make_grid_elements :: proc(columnCount, rowCount: int, pitch, size: [2]f32, z: f32) -> #soa[]ekhos.RectangularElement {
	elements := make(#soa[]ekhos.RectangularElement, columnCount * rowCount, context.allocator)
	index := 0
	for row in 0 ..< rowCount {
		for column in 0 ..< columnCount {
			x := (f32(column) - f32(columnCount - 1) * 0.5) * pitch[0]
			y := (f32(row) - f32(rowCount - 1) * 0.5) * pitch[1]
			elements[index] = {
				position    = {x, y, z},
				normal      = {0, 0, 1},
				size        = size,
				apodization = 1,
			}
			index += 1
		}
	}
	return elements
}

make_transmit_and_receive_grid_elements :: proc(columnCount, rowCount: int, pitch, size: [2]f32, z: f32) -> #soa[]ekhos.RectangularElement {
	transmitElements := make_grid_elements(columnCount, rowCount, pitch, size, z)
	receiveElements := make_grid_elements(columnCount, rowCount, pitch, size, z)
	elements := make(#soa[]ekhos.RectangularElement, len(transmitElements) + len(receiveElements), context.allocator)
	for i in 0 ..< len(transmitElements) {
		elements[i] = transmitElements[i]
	}
	for i in 0 ..< len(receiveElements) {
		elements[len(transmitElements) + i] = receiveElements[i]
	}
	defer delete(transmitElements)
	defer delete(receiveElements)
	return elements
}

make_full_aperture_transmissions :: proc(elementCount: int) -> []ekhos.Transmission {
	transmissionElements := make(#soa[]ekhos.ElementSetMember, elementCount, context.allocator)
	for i in 0 ..< elementCount {
		transmissionElements[i] = {
			index       = i32(i),
			apodization = 1,
			delay       = 0,
		}
	}
	transmissions := make([]ekhos.Transmission, 1, context.allocator)
	transmissions[0] = {
		elements = transmissionElements,
	}
	return transmissions
}

make_single_element_receive_channels :: proc(elementCount, elementIndexOffset: int) -> []ekhos.ReceiveChannel {
	receiveChannels := make([]ekhos.ReceiveChannel, elementCount, context.allocator)
	for i in 0 ..< elementCount {
		elements := make(#soa[]ekhos.ElementSetMember, 1, context.allocator)
		elements[0] = ekhos.ElementSetMember {
			index       = i32(elementIndexOffset + i),
			apodization = 1,
			delay       = 0,
		}
		receiveChannels[i] = {
			elements = elements,
		}
	}
	return receiveChannels
}

make_column_receive_channels :: proc(columnCount, rowCount, elementIndexOffset: int) -> []ekhos.ReceiveChannel {
	receiveChannels := make([]ekhos.ReceiveChannel, columnCount, context.allocator)
	for column in 0 ..< columnCount {
		elements := make(#soa[]ekhos.ElementSetMember, rowCount, context.allocator)
		for row in 0 ..< rowCount {
			elementIndex := elementIndexOffset + column * rowCount + row
			elements[row] = ekhos.ElementSetMember {
				index       = i32(elementIndex),
				apodization = 1,
				delay       = 0,
			}
		}
		receiveChannels[column] = {
			elements = elements,
		}
	}
	return receiveChannels
}
