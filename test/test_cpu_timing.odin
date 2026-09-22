package ekhos_scripts

import "core:log"
import "core:testing"
import "core:time"
import ekhos "ekhos:."
import utility "ekhos:utility"

CPU_TIMING_SCATTER_COUNT :: 1 << 18
CPU_TIMING_ITERATIONS :: 3

@(test)
cpuLinearArrayStageTimingTest :: proc(t: ^testing.T) {
	if !ekhos.CPU_STAGE_TIMING do return

	columnCount :: 128
	rowCount :: 128
	elementWidth: f32 : 2.2e-4
	elementKerf: f32 : 3e-5
	elementPitch :: elementWidth + elementKerf

	settings := ekhos.SimulationSettings {
		samplingFrequency = 100e6,
		speedOfSound = 1540,
		cumulative = false,
		cpuSettings = {threadCount = 1},
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
	scatters := make_random_scatters(CPU_TIMING_SCATTER_COUNT, {-8e-3, 8e-3}, {-2e-3, 2e-3}, {20e-3, 100e-3})
	defer delete(scatters)

	cpuSimulator, createOk := ekhos.create_cpu_simulator()
	if !utility.expect(t, createOk) do return
	cpuSim: ekhos.Simulator = cpuSimulator
	defer ekhos.destroy_cpu_simulator(&cpuSim.(ekhos.cpuSimulator))

	if !utility.expect(t, ekhos.plan_simulation(&cpuSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)) do return

	warmupData, warmupOk := ekhos.simulate(&cpuSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)
	if !utility.expect(t, warmupOk) do return
	delete(warmupData)

	totalSeconds: f64
	minimumSeconds: f64 = 3.4028235e38
	for _ in 0 ..< CPU_TIMING_ITERATIONS {
		stopwatch: time.Stopwatch
		time.stopwatch_start(&stopwatch)
		data, simulationOk := ekhos.simulate(&cpuSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)
		time.stopwatch_stop(&stopwatch)
		if !utility.expect(t, simulationOk) do return
		delete(data)

		seconds := time.duration_seconds(time.stopwatch_duration(stopwatch))
		totalSeconds += seconds
		minimumSeconds = min(minimumSeconds, seconds)
	}
	ekhos.log_simulation_timing(&cpuSim, "cpuLinearArrayStageTimingTest")

	log.infof(
		"CPU benchmark: elements=%d scatters=%d transmissions=%d receiveChannels=%d iterations=%d average=%.6fs minimum=%.6fs",
		len(elements),
		len(scatters),
		len(transmissions),
		len(receiveChannels),
		CPU_TIMING_ITERATIONS,
		totalSeconds / f64(CPU_TIMING_ITERATIONS),
		minimumSeconds,
	)
}
