package ekhos

import "core:mem"
import "core:thread"

hybridSimulator :: struct {
	cpu: cpuSimulator,
	gpu: vkSimulator,
}

HybridCpuJob :: struct {
	simulator:       ^cpuSimulator,
	settings:        SimulationSettings,
	transmissions:   []Transmission,
	receiveChannels: []ReceiveChannel,
	elements:        #soa[]RectangularElement,
	scatters:        []Scatter,
	impulses:        []TransducerImpulse,
	excitations:     []Excitation,
	allocator:       mem.Allocator,
	data:            []f32,
	ok:              bool,
}

create_hybrid_simulator :: proc(settings: SimulationSettings) -> (simulator: hybridSimulator, ok := true) {
	simulator.cpu, ok = create_cpu_simulator(resolve_cpu_thread_count(settings.cpuSettings.threadCount))
	if !ok do return
	gpu, gpuResult := create_vulkan_simulator(settings)
	if gpuResult != .SUCCESS {
		destroy_cpu_simulator(&simulator.cpu)
		return simulator, false
	}
	simulator.gpu = gpu
	return
}

destroy_hybrid_simulator :: proc(simulator: ^hybridSimulator) {
	destroy_cpu_simulator(&simulator.cpu)
	destroy_vulkan_simulator(&simulator.gpu)
	simulator^ = {}
}

hybrid_cpu_worker :: proc(data: rawptr) {
	job := cast(^HybridCpuJob)data
	context.allocator = job.allocator
	job.data, job.ok = simulate_cpu(
		job.simulator,
		job.settings,
		job.transmissions,
		job.receiveChannels,
		job.elements,
		job.scatters,
		job.impulses,
		job.excitations,
	)
}

simulate_hybrid :: proc(
	simulator: ^hybridSimulator,
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
	cpuScatterCount := int(f32(len(scatters)) * settings.hybridSettings.cpuScatterFraction)
	cpuScatters := scatters[:cpuScatterCount]
	gpuScatters := scatters[cpuScatterCount:]

	cpuJob := HybridCpuJob {
		simulator       = &simulator.cpu,
		settings        = settings^,
		transmissions   = transmissions,
		receiveChannels = receiveChannels,
		elements        = elements,
		scatters        = cpuScatters,
		impulses        = impulses,
		excitations     = excitations,
		allocator       = simulator.cpu.allocator,
		ok              = true,
	}
	cpuThread := thread.create_and_start_with_data(&cpuJob, hybrid_cpu_worker)

	gpuData, gpuResult := simulate_vulkan(&simulator.gpu, settings^, transmissions, receiveChannels, elements, gpuScatters, impulses, excitations, allocator)
	thread.destroy(cpuThread)
	if gpuResult != .SUCCESS || !cpuJob.ok {
		delete(gpuData, allocator)
		delete(cpuJob.data)
		return {}, false
	}

	data = gpuData
	for value, index in cpuJob.data {
		if index >= len(data) do break
		data[index] += value
	}
	delete(cpuJob.data)
	return
}
