package ekhos_scripts

import "core:testing"
import ekhos "ekhos:."
import utility "ekhos:utility"

GPU_TIMING_SCATTER_COUNT :: 1 << 18

@(test)
gpuLinearArrayStageTimingTest :: proc(t: ^testing.T) {
	if !ekhos.GPU_STAGE_TIMING do return

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
		gpuSettings = {enableDriverDebugMessages = false},
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
	scatters := make_random_scatters(GPU_TIMING_SCATTER_COUNT, {-8e-3, 8e-3}, {-2e-3, 2e-3}, {20e-3, 100e-3})
	defer delete(scatters)

	gpuSimulator, createResult := ekhos.create_vulkan_simulator(settings)
	if !utility.expect(t, createResult == .SUCCESS) do return
	gpuSim: ekhos.Simulator = gpuSimulator
	defer ekhos.destroy_vulkan_simulator(&gpuSim.(ekhos.vkSimulator))

	if !utility.expect(t, ekhos.plan_simulation(&gpuSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)) do return
	warmupData, warmupOk := ekhos.simulate(&gpuSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)
	if !utility.expect(t, warmupOk) do return
	delete(warmupData)

	data, simulationOk := ekhos.simulate(&gpuSim, &settings, transmissions, receiveChannels, elements, scatters, nil, nil)
	if data != nil do delete(data)
	_ = utility.expect(t, simulationOk)
	ekhos.log_simulation_timing(&gpuSim, "gpuLinearArrayStageTimingTest")
}
