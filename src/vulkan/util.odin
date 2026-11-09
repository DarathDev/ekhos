package ekhos_vulkan

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:time"
import ekhos_util "ekhos:utility"
import vk "vendor:vulkan"

API_VERSION_13 :: vk.API_VERSION_1_3

EKHOS_VULKAN_INITIALIZED := false

MESSENGER_BREAKPOINT :: #config(MESSENGER_BREAKPOINT, ODIN_DEBUG)

FILTER_VALIDATION_MESSAGES: []i32 : {}

// When false, only ERROR/WARNING vulkan messages are logged (suppresses INFO/VERBOSE spam, e.g. during tests).
LOG_DEBUG_VULKAN_MESSAGES :: false

GLOBAL_MODULE: dynlib.Library

when ODIN_OS == .Darwin {
	// NOTE: just a bogus import of the system library,
	// needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
	// when trying to load vulkan.
	@(require, extra_linker_flags = "-rpath /usr/local/lib")
	foreign import __ "system:System.framework"
}

@(init)
initialize :: proc "contextless" () {
	check :: ekhos_util.check

	// Source: https://github.com/Capati/odin-vk-bootstrap
	context = runtime.default_context()

	module: dynlib.Library
	loaded: bool

	// Load Vulkan library by platform
	when ODIN_OS == .Windows {
		module, loaded = dynlib.load_library("vulkan-1.dll")
	} else when ODIN_OS == .Darwin {
		module, loaded = dynlib.load_library("libvulkan.dylib", true)

		if !loaded {
			module, loaded = dynlib.load_library("libvulkan.1.dylib", true)
		}

		if !loaded {
			module, loaded = dynlib.load_library("libMoltenVK.dylib", true)
		}

		// Add support for using Vulkan and MoltenVK in a Framework. App store rules for iOS
		// strictly enforce no .dylib's. If they aren't found it just falls through
		if !loaded {
			module, loaded = dynlib.load_library("vulkan.framework/vulkan", true)
		}

		if !loaded {
			module, loaded = dynlib.load_library("MoltenVK.framework/MoltenVK", true)
			ta := context.temp_allocator
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			_, found_lib_path := os.lookup_env("DYLD_FALLBACK_LIBRARY_PATH", ta)
			// modern versions of macOS don't search /usr/local/lib automatically contrary to what
			// man dlopen says Vulkan SDK uses this as the system-wide installation location, so
			// we're going to fallback to this if all else fails
			if !loaded && !found_lib_path {
				module, loaded = dynlib.load_library("/usr/local/lib/libvulkan.dylib", true)
			}
		}
	} else {
		module, loaded = dynlib.load_library("libvulkan.so.1", true)
		if !loaded {
			module, loaded = dynlib.load_library("libvulkan.so", true)
		}
	}

	if !check(loaded, "Failed to load Vulkan library!") do return
	if !check(module != nil, "Failed to load Vulkan library module!") do return

	vkGetInstanceProcAddr, found := dynlib.symbol_address(module, "vkGetInstanceProcAddr")
	if !check(found, "Failed to get instance process address!") do return

	// Load the base vulkan procedures before we start using them
	vk.load_proc_addresses_global(vkGetInstanceProcAddr)
	if !check(vk.CreateInstance != nil, "vulkan function pointers not loaded") do return
	GLOBAL_MODULE = module
	EKHOS_VULKAN_INITIALIZED = true
}

byte_arr_str :: proc(arr: ^[$N]byte) -> string {
	return strings.string_from_null_terminated_ptr(raw_data(arr), N)
}

// Like log.infof, but suppressed when LOG_DEBUG_VULKAN_MESSAGES is false.
log_debug_infof :: proc(format: string, args: ..any, loc := #caller_location) {
	if !LOG_DEBUG_VULKAN_MESSAGES do return
	log.infof(format, ..args, location = loc)
}

vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {

	if slice.contains(FILTER_VALIDATION_MESSAGES, pCallbackData.messageIdNumber) do return false

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	if !LOG_DEBUG_VULKAN_MESSAGES && level != .Error && level != .Warning do return false

	debugUserData: ^DebugUserData = auto_cast pUserData
	if debugUserData != nil && debugUserData.logger != {} {
		context = runtime.default_context()
		context.logger = debugUserData.logger
		log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	}

	when MESSENGER_BREAKPOINT {
		if .ERROR in messageSeverity {
			time.sleep(5 * time.Millisecond) // Allows the error message to be printed to the console
			runtime.debug_trap()
		}
	}
	return false
}

name :: proc {
	name_device,
	name_swapchain,
	name_surface,
	name_device_memory,
	name_sampler,
	name_buffer,
	name_image,
	name_buffer_view,
	name_image_view,
	name_semaphore,
	name_fence,
	name_event,
	name_command_pool,
	name_command_buffer,
	name_descriptor_set_layout,
	name_descriptor_set,
	name_descriptor_pool,
	name_shader_module,
	name_shader_object,
	name_pipeline_layout,
	name_pipeline,
}

name_device :: proc(device: Device, name: string) -> vk.Result {
	return name_object(device, cast(u64)uintptr(device.device), .DEVICE, name)
}

name_swapchain :: proc(device: Device, swapchain: vk.SwapchainKHR, name: string) -> vk.Result {
	return name_object(device, cast(u64)swapchain, .SWAPCHAIN_KHR, name)
}

name_surface :: proc(device: Device, surface: vk.SurfaceKHR, name: string) -> vk.Result {
	return name_object(device, cast(u64)surface, .SURFACE_KHR, name)
}

name_device_memory :: proc(device: Device, deviceMemory: vk.DeviceMemory, name: string) -> vk.Result {
	return name_object(device, cast(u64)deviceMemory, .DEVICE_MEMORY, name)
}

name_sampler :: proc(device: Device, sampler: vk.Sampler, name: string) -> vk.Result {
	return name_object(device, cast(u64)sampler, .SAMPLER, name)
}

name_buffer :: proc(device: Device, buffer: vk.Buffer, name: string) -> vk.Result {
	return name_object(device, cast(u64)buffer, .BUFFER, name)
}

name_image :: proc(device: Device, image: vk.Image, name: string) -> vk.Result {
	return name_object(device, cast(u64)image, .IMAGE, name)
}

name_buffer_view :: proc(device: Device, bufferView: vk.BufferView, name: string) -> vk.Result {
	return name_object(device, cast(u64)bufferView, .BUFFER_VIEW, name)
}

name_image_view :: proc(device: Device, imageView: vk.ImageView, name: string) -> vk.Result {
	return name_object(device, cast(u64)imageView, .IMAGE_VIEW, name)
}

name_semaphore :: proc(device: Device, semaphore: vk.Semaphore, name: string) -> vk.Result {
	return name_object(device, cast(u64)semaphore, .SEMAPHORE, name)
}

name_fence :: proc(device: Device, fence: vk.Fence, name: string) -> vk.Result {
	return name_object(device, cast(u64)fence, .FENCE, name)
}

name_event :: proc(device: Device, event: vk.Event, name: string) -> vk.Result {
	return name_object(device, cast(u64)event, .EVENT, name)
}

name_command_pool :: proc(device: Device, commandPool: vk.CommandPool, name: string) -> vk.Result {
	return name_object(device, cast(u64)uintptr(commandPool), .COMMAND_POOL, name)
}

name_command_buffer :: proc(device: Device, commandBuffer: vk.CommandBuffer, name: string) -> vk.Result {
	return name_object(device, cast(u64)uintptr(commandBuffer), .COMMAND_BUFFER, name)
}

name_descriptor_set_layout :: proc(device: Device, layout: vk.DescriptorSetLayout, name: string) -> vk.Result {
	return name_object(device, cast(u64)layout, .DESCRIPTOR_SET_LAYOUT, name)
}

name_descriptor_set :: proc(device: Device, descriptorSet: vk.DescriptorSet, name: string) -> vk.Result {
	return name_object(device, cast(u64)descriptorSet, .DESCRIPTOR_SET, name)
}

name_descriptor_pool :: proc(device: Device, pool: vk.DescriptorPool, name: string) -> vk.Result {
	return name_object(device, cast(u64)pool, .DESCRIPTOR_POOL, name)
}

name_shader_module :: proc(device: Device, module: vk.ShaderModule, name: string) -> vk.Result {
	return name_object(device, cast(u64)module, .SHADER_MODULE, name)
}

name_shader_object :: proc(device: Device, shader: vk.ShaderEXT, name: string) -> vk.Result {
	return name_object(device, cast(u64)shader, .SHADER_EXT, name)
}

name_pipeline_layout :: proc(device: Device, layout: vk.PipelineLayout, name: string) -> vk.Result {
	return name_object(device, cast(u64)layout, .PIPELINE_LAYOUT, name)
}

name_pipeline :: proc(device: Device, pipeline: vk.Pipeline, name: string) -> vk.Result {
	return name_object(device, cast(u64)pipeline, .PIPELINE, name)
}

@(private)
get_object_type_prefix :: proc(objectType: vk.ObjectType) -> string {
	#partial switch objectType {
	case .DEVICE:
		return "Device"
	case .SWAPCHAIN_KHR:
		return "Swapchain"
	case .SURFACE_KHR:
		return "Surface"
	case .DEVICE_MEMORY:
		return "DeviceMemory"
	case .BUFFER:
		return "Buffer"
	case .IMAGE:
		return "Image"
	case .BUFFER_VIEW:
		return "BufferView"
	case .IMAGE_VIEW:
		return "ImageView"
	case .SEMAPHORE:
		return "Semaphore"
	case .FENCE:
		return "Fence"
	case .EVENT:
		return "Event"
	case .COMMAND_POOL:
		return "CommandPool"
	case .COMMAND_BUFFER:
		return "CommandBuffer"
	case .DESCRIPTOR_SET_LAYOUT:
		return "DescriptorSetLayout"
	case .DESCRIPTOR_SET:
		return "DescriptorSet"
	case .DESCRIPTOR_POOL:
		return "DescriptorPool"
	case .SHADER_MODULE:
		return "ShaderModule"
	case .SHADER_EXT:
		return "Shader"
	case .PIPELINE_LAYOUT:
		return "PipelineLayout"
	case .PIPELINE:
		return "Pipeline"
	}
	return ""
}

@(private)
format_object_label :: proc(objectType: vk.ObjectType, label: string) -> string {
	prefix := get_object_type_prefix(objectType)
	if len(prefix) == 0 || len(label) == 0 do return label
	return fmt.tprintf("%s %s", label, prefix)
}

@(private)
name_object :: proc(device: Device, objectHandle: u64, objectType: vk.ObjectType, name: string) -> vk.Result {
	if .DebugUtils in device.instanceCapabilities {
		formattedName := format_object_label(objectType, name)
		pName := strings.clone_to_cstring(formattedName, context.temp_allocator)
		nameInfo: vk.DebugUtilsObjectNameInfoEXT = {
			sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
			objectType   = objectType,
			objectHandle = objectHandle,
			pObjectName  = pName,
		}
		return vk.SetDebugUtilsObjectNameEXT(device.device, &nameInfo)
	} else {
		return .SUCCESS
	}
}

get_bytes_per_pixel :: proc(format: vk.Format) -> u32 {
	#partial switch format {
	// 8-bit formats
	case .R8_UNORM, .R8_SNORM, .R8_UINT, .R8_SINT, .R8_SRGB:
		return 1
	case .R8G8_UNORM, .R8G8_SNORM, .R8G8_UINT, .R8G8_SINT, .R8G8_SRGB:
		return 2
	case .R8G8B8_UNORM, .R8G8B8_SNORM, .R8G8B8_UINT, .R8G8B8_SINT, .R8G8B8_SRGB:
		return 3
	case .R8G8B8A8_UNORM, .R8G8B8A8_SNORM, .R8G8B8A8_UINT, .R8G8B8A8_SINT, .R8G8B8A8_SRGB:
		return 4
	case .B8G8R8A8_UNORM, .B8G8R8A8_SRGB, .A8B8G8R8_UNORM_PACK32, .A8B8G8R8_SRGB_PACK32:
		return 4

	// 16-bit formats
	case .R16_UNORM, .R16_SNORM, .R16_UINT, .R16_SINT, .R16_SFLOAT:
		return 2
	case .R16G16_UNORM, .R16G16_SNORM, .R16G16_UINT, .R16G16_SINT, .R16G16_SFLOAT:
		return 4
	case .R16G16B16_UNORM, .R16G16B16_SNORM, .R16G16B16_UINT, .R16G16B16_SINT, .R16G16B16_SFLOAT:
		return 6
	case .R16G16B16A16_UNORM, .R16G16B16A16_SNORM, .R16G16B16A16_UINT, .R16G16B16A16_SINT, .R16G16B16A16_SFLOAT:
		return 8

	// 32-bit formats
	case .R32_UINT, .R32_SINT, .R32_SFLOAT:
		return 4
	case .R32G32_UINT, .R32G32_SINT, .R32G32_SFLOAT:
		return 8
	case .R32G32B32_UINT, .R32G32B32_SINT, .R32G32B32_SFLOAT:
		return 12
	case .R32G32B32A32_UINT, .R32G32B32A32_SINT, .R32G32B32A32_SFLOAT:
		return 16

	// 64-bit formats
	case .R64_UINT, .R64_SINT, .R64_SFLOAT:
		return 8
	case .R64G64_UINT, .R64G64_SINT, .R64G64_SFLOAT:
		return 16
	case .R64G64B64_UINT, .R64G64B64_SINT, .R64G64B64_SFLOAT:
		return 24
	case .R64G64B64A64_UINT, .R64G64B64A64_SINT, .R64G64B64A64_SFLOAT:
		return 32

	// 10/11-bit packed formats
	case .A2R10G10B10_UNORM_PACK32, .A2B10G10R10_UNORM_PACK32, .A2R10G10B10_UINT_PACK32, .A2B10G10R10_UINT_PACK32:
		return 4
	case .B10G11R11_UFLOAT_PACK32, .E5B9G9R9_UFLOAT_PACK32:
		return 4

	// Depth/stencil formats
	case .D16_UNORM:
		return 2
	case .X8_D24_UNORM_PACK32, .D24_UNORM_S8_UINT:
		return 4
	case .D32_SFLOAT:
		return 4
	case .D32_SFLOAT_S8_UINT:
		return 8
	case .D16_UNORM_S8_UINT:
		return 4
	}
	return 0
}

get_buffer_address :: proc(device: Device, buffer: Buffer) -> vk.DeviceAddress {
	addressInfo: vk.BufferDeviceAddressInfo = {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = buffer.buffer,
	}
	return vk.GetBufferDeviceAddress(device.device, &addressInfo)
}

get_all_shader_stages :: proc(device: Device) -> (stageFlags: vk.ShaderStageFlags) {
	stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE}
	if .MeshShader in device.enabledCapabilities {
		stageFlags |= {.MESH_EXT}
	}
	if .TaskShader in device.enabledCapabilities {
		stageFlags |= {.TASK_EXT}
	}
	return
}

get_all_pipeline_shader_stages :: proc(device: Device) -> (stageFlags: vk.PipelineStageFlags2) {
	stageFlags = {.VERTEX_INPUT, .FRAGMENT_SHADER, .COMPUTE_SHADER}
	if .MeshShader in device.enabledCapabilities {
		stageFlags |= {.MESH_SHADER_EXT}
	}
	if .TaskShader in device.enabledCapabilities {
		stageFlags |= {.TASK_SHADER_EXT}
	}
	return
}

is_mapped :: proc {
	buffer_is_mapped,
	image_is_mapped,
}

buffer_is_mapped :: proc(buffer: Buffer) -> bool {
	return .HOST_VISIBLE in buffer.memory.properties && buffer.memory.mappedData != nil
}

image_is_mapped :: proc(image: Image) -> bool {
	return .HOST_VISIBLE in image.memory.properties && image.memory.mappedData != nil
}

get_mapped_data :: proc {
	get_buffer_mapped_data,
	get_image_mapped_data,
}

get_buffer_mapped_data :: proc(buffer: Buffer) -> []byte {
	assert(is_mapped(buffer))
	assert(buffer.memory.size >= auto_cast (buffer.offset + buffer.size))
	return (cast([^]byte)buffer.memory.mappedData)[buffer.offset:][:buffer.size]
}

get_image_mapped_data :: proc(image: Image) -> []byte {
	assert(is_mapped(image))
	assert(image.tiling == .LINEAR)
	assert(image.memory.size >= auto_cast (image.offset + image.size))
	return (cast([^]byte)image.memory.mappedData)[image.offset:][:image.size]
}

get_timeline_value :: proc(device: Device, semaphore: TimelineSemaphore, loc := #caller_location) -> (value: u64, bool := true) {
	ekhos_util.is_ok(ekhos_util.check(vk.GetSemaphoreCounterValue(device.device, auto_cast semaphore, &value), loc = loc)) or_return
	assert(value != ~{}, "Typically signifies a Silent Device Loss, such as from a TDR")
	return
}

make_dependency_info :: proc(
	memoryBarriers: []vk.MemoryBarrier2 = {},
	bufferBarriers: []vk.BufferMemoryBarrier2 = {},
	imageBarriers: []vk.ImageMemoryBarrier2 = {},
) -> vk.DependencyInfo {
	for &barrier in memoryBarriers do barrier.sType = .MEMORY_BARRIER_2
	for &barrier in bufferBarriers do barrier.sType = .BUFFER_MEMORY_BARRIER_2
	for &barrier in imageBarriers do barrier.sType = .IMAGE_MEMORY_BARRIER_2
	return {
		sType = .DEPENDENCY_INFO,
		memoryBarrierCount = u32(len(memoryBarriers)),
		pMemoryBarriers = raw_data(memoryBarriers),
		bufferMemoryBarrierCount = u32(len(bufferBarriers)),
		pBufferMemoryBarriers = raw_data(bufferBarriers),
		imageMemoryBarrierCount = u32(len(imageBarriers)),
		pImageMemoryBarriers = raw_data(imageBarriers),
	}
}

cmd_push_constants :: proc {
	cmd_push_constants_struct,
	cmd_push_constants_bytes,
}

cmd_push_constants_struct :: proc(
	commandBuffer: CommandBuffer,
	layout: vk.PipelineLayout,
	stages: vk.ShaderStageFlags,
	data: $T,
) where intrinsics.type_is_struct(T) {
	data := data
	vk.CmdPushConstants(commandBuffer.commandBuffer, layout, stages, 0, size_of(T), &data)
}

cmd_push_constants_bytes :: proc(commandBuffer: CommandBuffer, layout: vk.PipelineLayout, stages: vk.ShaderStageFlags, data: []byte) {
	vk.CmdPushConstants(commandBuffer.commandBuffer, layout, stages, 0, u32(len(data)), raw_data(data))
}
