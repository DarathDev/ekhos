package ekhos_scripts

import "core:log"
import "core:testing"
import "core:time"
import ekhos "ekhos:."
import utility "ekhos:utility"

HYBRID_TIMING_SCATTER_COUNT :: 1 << 10
HYBRID_TIMING_ITERATIONS :: 10
HYBRID_TIMING_CPU_SCATTER_FRACTION :: f32(#config(HYBRID_TIMING_CPU_SCATTER_FRACTION, 0.5))
HYBRID_TIMING_THREAD_COUNT :: #config(HYBRID_TIMING_THREAD_COUNT, 1)

@(test)
hybridLinearArrayStageTimingTest :: proc(t: ^testing.T) {
	if !ekhos.CPU_STAGE_TIMING && !ekhos.GPU_STAGE_TIMING do return

	columnCount :: 128
	rowCount :: 128
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	settings := ekhos.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = false,
		cpuSettings = {threadCount = HYBRID_TIMING_THREAD_COUNT},
		gpuSettings = {enableDriverDebugMessages = false},
		hybridSettings = {cpuScatterFraction = HYBRID_TIMING_CPU_SCATTER_FRACTION},
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
	scatters := make_random_scatters(HYBRID_TIMING_SCATTER_COUNT, {-8e-3, 8e-3}, {-2e-3, 2e-3}, {20e-3, 100e-3})
	defer delete(scatters)

	hybridSimulator, createOk := ekhos.create_hybrid_simulator(settings)
	if !utility.expect(t, createOk) do return
	hybridSim: ekhos.Simulator = hybridSimulator
	defer ekhos.destroy_hybrid_simulator(&hybridSim.(ekhos.hybridSimulator))

	if !utility.expect(t, ekhos.plan_simulation(&hybridSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)) do return
	warmupData, warmupOk := ekhos.simulate(&hybridSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)
	if !utility.expect(t, warmupOk) do return
	delete(warmupData)

	totalSeconds: f64
	minimumSeconds: f64 = 3.4028235e38
	for _ in 0 ..< HYBRID_TIMING_ITERATIONS {
		stopwatch: time.Stopwatch
		time.stopwatch_start(&stopwatch)
		data, simulationOk := ekhos.simulate(&hybridSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)
		time.stopwatch_stop(&stopwatch)
		if !utility.expect(t, simulationOk) do return
		delete(data)

		seconds := time.duration_seconds(time.stopwatch_duration(stopwatch))
		totalSeconds += seconds
		minimumSeconds = min(minimumSeconds, seconds)
	}
	ekhos.log_simulation_timing(&hybridSim, "hybridLinearArrayStageTimingTest")

	log.infof(
		"Hybrid benchmark: elements=%d scatters=%d cpuScatterFraction=%.2f transmissions=%d receiveChannels=%d iterations=%d average=%.6fs minimum=%.6fs",
		len(elements),
		len(scatters),
		HYBRID_TIMING_CPU_SCATTER_FRACTION,
		len(transmissions),
		len(receiveChannels),
		HYBRID_TIMING_ITERATIONS,
		totalSeconds / f64(HYBRID_TIMING_ITERATIONS),
		minimumSeconds,
	)
}
