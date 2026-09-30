package ekhos

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "ekhos:utility"
import ekhos_vk "ekhos:vulkan"

@(export)
create_cpu_simulator_c :: proc "c" (simulator: ^^Simulator, cLogger: cLogProc = nil, cAssert: cAssertProc = nil, userData: rawptr = nil) -> (ok := true) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	simulator^ = new(Simulator)
	simulator^^, ok = create_cpu_simulator()
	return
}

@(export)
destroy_cpu_simulator_c :: proc "c" (simulator: ^Simulator, cLogger: cLogProc = nil, cAssert: cAssertProc = nil, userData: rawptr = nil) -> (ok := true) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	utility.check(simulator != nil) or_return
	switch &sim in simulator {
	case cpuSimulator:
		destroy_cpu_simulator(&sim)
	case vkSimulator, hybridSimulator:
	}
	return
}

@(export)
create_vulkan_simulator_c :: proc "c" (
	simulator: ^^Simulator,
	settings: ^SimulationSettings,
	cLogger: cLogProc = nil,
	cAssert: cAssertProc = nil,
	userData: rawptr = nil,
) -> (
	ok := true,
) {
	if !ekhos_vk.EKHOS_VULKAN_INITIALIZED {
		ekhos_vk.initialize()
	}
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	simulator^ = new(Simulator)
	utility.check(settings != nil) or_return
	simulator^^, ok = utility.is_ok(create_vulkan_simulator(settings^))
	return
}

@(export)
destroy_vulkan_simulator_c :: proc "c" (simulator: ^Simulator, cLogger: cLogProc = nil, cAssert: cAssertProc = nil, userData: rawptr = nil) -> (ok := true) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	utility.check(simulator != nil) or_return
	if vkSimulator, vkSimOk := simulator.(vkSimulator); vkSimOk {
		destroy_vulkan_simulator(&vkSimulator)
	}
	return
}

@(export)
create_hybrid_simulator_c :: proc "c" (
	simulator: ^^Simulator,
	settings: ^SimulationSettings,
	cLogger: cLogProc = nil,
	cAssert: cAssertProc = nil,
	userData: rawptr = nil,
) -> (
	ok := true,
) {
	if !ekhos_vk.EKHOS_VULKAN_INITIALIZED {
		ekhos_vk.initialize()
	}
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	simulator^ = new(Simulator)
	utility.check(settings != nil) or_return
	simulator^^, ok = create_hybrid_simulator(settings^)
	return
}

@(export)
destroy_hybrid_simulator_c :: proc "c" (simulator: ^Simulator, cLogger: cLogProc = nil, cAssert: cAssertProc = nil, userData: rawptr = nil) -> (ok := true) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	utility.check(simulator != nil) or_return
	switch &sim in simulator {
	case hybridSimulator:
		destroy_hybrid_simulator(&sim)
	case cpuSimulator, vkSimulator:
	}
	return
}

@(export)
plan_simulation_c :: proc "c" (
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
	impulses: []TransducerImpulse,
	excitations: []Excitation,
	cLogger: cLogProc = nil,
	cAssert: cAssertProc = nil,
	userData: rawptr = nil,
) -> (
	ok := true,
) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	return plan_simulation(simulator, settings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
}

@(export)
simulate_c :: proc "c" (
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
	impulses: []TransducerImpulse,
	excitations: []Excitation,
	pulseEcho: [^]f32,
	cLogger: cLogProc = nil,
	cAssert: cAssertProc = nil,
	userData: rawptr = nil,
) -> bool {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, userData)
	context.assertion_failure_proc = c_assertion(cAssert, userData)
	data, ok := simulate(simulator, settings, transmissions, receiveChannels, elements, scatters, impulses, excitations)
	copy(pulseEcho[:len(data)], data)
	delete(data)
	free_all(context.temp_allocator)
	return ok
}

cLogProc :: #type proc "c" (pUserData: rawptr, string: cstring)
cAssertProc :: #type proc "c" (pUserData: rawptr, string: cstring)

c_assertion_proc_callback: cAssertProc
c_assertion_proc_user_data: rawptr

@(private = "file")
c_assertion :: proc(c: cAssertProc, pUserData: rawptr) -> runtime.Assertion_Failure_Proc {
	c_assertion_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
		if c_assertion_proc_callback != nil {
			full_message := fmt.tprintf("%s(%v:%v) %s: %s", loc.file_path, loc.line, loc.column, prefix, message)
			c_assertion_proc_callback(c_assertion_proc_user_data, strings.clone_to_cstring(full_message, context.temp_allocator))
		}
		runtime.default_assertion_failure_proc(prefix, message, loc)
	}
	c_assertion_proc_callback = c
	c_assertion_proc_user_data = pUserData
	return c_assertion_proc
}

@(private = "file")
c_logger :: proc(l: log.Logger, c: cLogProc, pUserData: rawptr) -> log.Logger {
	c_logger_data :: struct {
		wrappedLogger: log.Logger,
		cLogProc:      cLogProc,
		pUserData:     rawptr,
	}
	c_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, locations := #caller_location) {
		data := cast(^c_logger_data)data
		if (data.cLogProc != nil) {
			data.cLogProc(data.pUserData, strings.clone_to_cstring(text, context.temp_allocator))
		}
		data.wrappedLogger.procedure(data.wrappedLogger.data, level, text, options, locations)
	}

	logger_data := new(c_logger_data, context.allocator)
	logger_data.wrappedLogger = context.logger
	logger_data.cLogProc = c
	logger_data.pUserData = pUserData
	return log.Logger {
		data = logger_data,
		lowest_level = logger_data.wrappedLogger.lowest_level,
		options = logger_data.wrappedLogger.options,
		procedure = c_logger_proc,
	}
}
