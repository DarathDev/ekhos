package ekhos_vulkan

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/bits"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"
import ekhos_util "ekhos:utility"

@(private = "file")
assume :: ekhos_util.assume
@(private = "file")
assert :: ekhos_util.assert
@(private = "file")
check :: ekhos_util.check

VK_VALIDATION_LAYER_NAME :: "VK_LAYER_KHRONOS_validation"
VK_SHADER_OBJECT_LAYER_NAME :: "VK_LAYER_KHRONOS_shader_object"

PRESENT_SUBCAPABILITIES: InstanceCapabilities : {.PresentWin32, .PresentMetal, .PresentXcb, .PresentXLib, .PresentWayland}

DEVICE_FEATURE_EXTENSIONS: [DeviceCapability][]string : #partial{
	.AtomicAddFloat32Buffer = {vk.EXT_SHADER_ATOMIC_FLOAT_EXTENSION_NAME},
	.Swapchain = {vk.KHR_SWAPCHAIN_EXTENSION_NAME},
	.SwapchainMaintenance = {vk.EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME},
	.MeshShader = {vk.EXT_MESH_SHADER_EXTENSION_NAME},
	.FifoLatestReady = {vk.EXT_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME},
	.ShaderObject = {vk.EXT_SHADER_OBJECT_EXTENSION_NAME},
	.ExternalMemoryHost = {vk.EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME},
	.SubgroupRotate = {vk.KHR_SHADER_SUBGROUP_ROTATE_EXTENSION_NAME},
	.DynamicLocalRead = {vk.KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME},
	.Robustness2 = {vk.EXT_ROBUSTNESS_2_EXTENSION_NAME},
	.Barycentric = {vk.KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME},
}

deduce_instance_capabilities :: proc(layers: []vk.LayerProperties, extensions: []vk.ExtensionProperties) -> (capabilities: InstanceCapabilities) {
	for &layer in layers {
		switch (byte_arr_str(&layer.layerName)) {
		case VK_VALIDATION_LAYER_NAME:
			capabilities |= {.Validation}
		case VK_SHADER_OBJECT_LAYER_NAME:
			capabilities |= {.ShaderObject}
		}
	}
	for &extension in extensions {
		switch (byte_arr_str(&extension.extensionName)) {
		case vk.KHR_SURFACE_EXTENSION_NAME:
			capabilities |= {.Present}
		case vk.KHR_WIN32_SURFACE_EXTENSION_NAME:
			capabilities |= {.PresentWin32}
		case vk.EXT_METAL_SURFACE_EXTENSION_NAME:
			capabilities |= {.PresentMetal}
		case vk.KHR_XCB_SURFACE_EXTENSION_NAME:
			capabilities |= {.PresentXcb}
		case vk.KHR_XLIB_SURFACE_EXTENSION_NAME:
			capabilities |= {.PresentXLib}
		case vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME:
			capabilities |= {.PresentWayland}
		case vk.EXT_DEBUG_UTILS_EXTENSION_NAME:
			capabilities |= {.DebugUtils}
		case vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME:
			capabilities |= {.Portability}
		}
	}

	if capabilities & PRESENT_SUBCAPABILITIES == {} { capabilities -= {.Present} }
	return
}

make_instance_flags :: proc(capabilities: InstanceCapabilities) -> (flags: vk.InstanceCreateFlags) {
	if .Portability in capabilities { flags += {.ENUMERATE_PORTABILITY_KHR} }
	return
}

make_instance_layer_names :: proc(capabilities: InstanceCapabilities, allocator := context.allocator) -> (layers: []cstring) {
	dLayers := make([dynamic]cstring, allocator)
	if .Validation in capabilities { append(&dLayers, VK_VALIDATION_LAYER_NAME) }
	if .ShaderObject in capabilities { append(&dLayers, VK_SHADER_OBJECT_LAYER_NAME) }
	shrink(&dLayers); layers = dLayers[:]
	return
}

make_instance_extension_names :: proc(capabilities: InstanceCapabilities, allocator := context.allocator) -> (extensions: []cstring) {
	dExtensions := make([dynamic]cstring, allocator)
	if .Present in capabilities { append(&dExtensions, vk.KHR_SURFACE_EXTENSION_NAME) }
	if .PresentWin32 in capabilities { append(&dExtensions, vk.KHR_WIN32_SURFACE_EXTENSION_NAME) }
	if .PresentMetal in capabilities { append(&dExtensions, vk.EXT_METAL_SURFACE_EXTENSION_NAME) }
	if .PresentXcb in capabilities { append(&dExtensions, vk.KHR_XCB_SURFACE_EXTENSION_NAME) }
	if .PresentXLib in capabilities { append(&dExtensions, vk.KHR_XLIB_SURFACE_EXTENSION_NAME) }
	if .PresentWayland in capabilities { append(&dExtensions, vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME) }
	if .DebugUtils in capabilities { append(&dExtensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME) }
	if .Portability in capabilities { append(&dExtensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) }
	shrink(&dExtensions); extensions = dExtensions[:]
	return
}

deduce_device_capabilities :: proc(features2: vk.PhysicalDeviceFeatures2, extensions: []vk.ExtensionProperties) -> (capabilities: DeviceCapabilities) {
	// We start with all capabilities set as the unsetting operator allows for early exit if any requirements are unmet
	capabilities = ~{}

	if !features2.features.geometryShader { capabilities -= {.GeometryShaders} }
	if !features2.features.tessellationShader { capabilities -= {.TessellationShaders} }
	if !features2.features.sampleRateShading { capabilities -= {.SampleRateShading} }
	if !features2.features.logicOp { capabilities -= {.LogicOp} }
	if !features2.features.multiDrawIndirect { capabilities -= {.MultiDrawIndirect} }
	if !features2.features.depthClamp { capabilities -= {.DepthClamp} }
	if !features2.features.depthBounds { capabilities -= {.DepthBounds} }
	if !features2.features.wideLines { capabilities -= {.WideLines} }
	if !features2.features.largePoints { capabilities -= {.LargePoints} }
	if !features2.features.multiViewport { capabilities -= {.MultiViewport} }
	if !features2.features.samplerAnisotropy { capabilities -= {.SamplerAnisotropy} }
	if !features2.features.shaderFloat64 { capabilities -= {.ShaderFloat64} }
	if !features2.features.shaderInt64 { capabilities -= {.ShaderInt64} }
	if !features2.features.shaderInt16 { capabilities -= {.ShaderInt16} }
	if !features2.features.robustBufferAccess { capabilities -= {.Robustness2} }
	pNext: ^vk.BaseInStructure = auto_cast features2.pNext
	for pNext != nil {
		#partial switch pNext.sType {
		case .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES:
			vulkan11Features := ((cast(^vk.PhysicalDeviceVulkan11Features)pNext)^)
			if !vulkan11Features.multiview { capabilities -= {.MultiView} }
			if !vulkan11Features.shaderDrawParameters { capabilities -= {.ShaderDrawParameters} }
		case .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES:
			vulkan12Features := ((cast(^vk.PhysicalDeviceVulkan12Features)pNext)^)
			if !vulkan12Features.drawIndirectCount { capabilities -= {.DrawIndirectCount} }
			if !vulkan12Features.shaderFloat16 { capabilities -= {.ShaderFloat16} }
			if !vulkan12Features.shaderInt8 { capabilities -= {.ShaderInt8} }
			if !vulkan12Features.descriptorIndexing { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingUniformBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingSampledImageUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingStorageImageUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingStorageBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingUniformTexelBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingStorageTexelBufferUpdateAfterBind { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingUpdateUnusedWhilePending { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.descriptorBindingPartiallyBound { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.runtimeDescriptorArray { capabilities -= {.DescriptorIndexing} }
			if !vulkan12Features.timelineSemaphore { capabilities -= {.TimelineSemaphore} }
			if !vulkan12Features.bufferDeviceAddress { capabilities -= {.BufferDeviceAddress} }
			if !vulkan12Features.descriptorBindingVariableDescriptorCount { capabilities -= {.VariableDescriptorCount} }
			if !vulkan12Features.scalarBlockLayout { capabilities -= {.ScalarBlockLayout} }
		case .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES:
			vulkan13Features := ((cast(^vk.PhysicalDeviceVulkan13Features)pNext)^)
			if !vulkan13Features.synchronization2 { capabilities -= {.Synchronization2} }
			if !vulkan13Features.dynamicRendering { capabilities -= {.DynamicRendering} }
			if !vulkan13Features.maintenance4 { capabilities -= {.Maintenance4} }
		case .PHYSICAL_DEVICE_SHADER_SUBGROUP_ROTATE_FEATURES_KHR:
			subgroupRotateFeatures := ((cast(^vk.PhysicalDeviceShaderSubgroupRotateFeatures)pNext)^)
			if !subgroupRotateFeatures.shaderSubgroupRotate { capabilities -= {.SubgroupRotate} }
			if !subgroupRotateFeatures.shaderSubgroupRotateClustered { capabilities -= {.SubgroupRotate} }
		case .PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR:
			dynamicLocalReadFeatures := ((cast(^vk.PhysicalDeviceDynamicRenderingLocalReadFeaturesKHR)pNext)^)
			if !dynamicLocalReadFeatures.dynamicRenderingLocalRead { capabilities -= {.DynamicLocalRead} }
		case .PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT:
			atomicFloatFeatures := ((cast(^vk.PhysicalDeviceShaderAtomicFloatFeaturesEXT)pNext)^)
			if !atomicFloatFeatures.shaderBufferFloat32AtomicAdd { capabilities -= {.AtomicAddFloat32Buffer} }
		case .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT:
			swapchainMaintenance1 := ((cast(^vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT)pNext)^)
			if !swapchainMaintenance1.swapchainMaintenance1 { capabilities -= {.SwapchainMaintenance} }
		case .PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_EXT:
			presentModeFifoLatestReady := ((cast(^vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesEXT)pNext)^)
			if !presentModeFifoLatestReady.presentModeFifoLatestReady { capabilities -= {.FifoLatestReady} }
		case .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT:
			shaderObject := ((cast(^vk.PhysicalDeviceShaderObjectFeaturesEXT)pNext)^)
			if !shaderObject.shaderObject { capabilities -= {.ShaderObject} }
		case .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT:
			meshShader := ((cast(^vk.PhysicalDeviceMeshShaderFeaturesEXT)pNext)^)
			if !meshShader.meshShader { capabilities -= {.MeshShader} }
			if !meshShader.taskShader { capabilities -= {.TaskShader} }
		case .PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT:
			robustness2 := ((cast(^vk.PhysicalDeviceRobustness2FeaturesEXT)pNext)^)
			if !robustness2.robustBufferAccess2 { capabilities -= {.Robustness2} }
			if !robustness2.robustImageAccess2 { capabilities -= {.Robustness2} }
			if !robustness2.nullDescriptor { capabilities -= {.Robustness2} }
		case .PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR:
			barycentric := ((cast(^vk.PhysicalDeviceFragmentShaderBarycentricFeaturesKHR)pNext)^)
			if !barycentric.fragmentShaderBarycentric { capabilities -= {.Barycentric} }
		}
		pNext = auto_cast pNext.pNext
	}

	featureExtensions := DEVICE_FEATURE_EXTENSIONS
	for feature in DeviceCapability {
		if feature not_in capabilities {
			continue
		}
		extensionLoop: for requiredExtension in featureExtensions[feature] {
			for &availableExtension in extensions {
				pDeviceExtension := byte_arr_str(&availableExtension.extensionName)
				if strings.compare(requiredExtension, pDeviceExtension) == 0 {
					continue extensionLoop
				}
			}
			capabilities -= {feature}
		}
	}
	return
}

regularize_device_capabilities :: proc(capabilities: ^DeviceCapabilities) {
	if .TaskShader in capabilities { capabilities^ |= {.MeshShader} }
	if .MeshShader not_in capabilities { capabilities^ &~= {.TaskShader} }
}

make_device_features :: proc(
	capabilities: DeviceCapabilities,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	features2: vk.PhysicalDeviceFeatures2,
) {
	capabilities := capabilities
	regularize_device_capabilities(&capabilities)
	features2 = {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		features = {
			geometryShader = .GeometryShaders in capabilities,
			tessellationShader = .TessellationShaders in capabilities,
			sampleRateShading = .SampleRateShading in capabilities,
			logicOp = .LogicOp in capabilities,
			multiDrawIndirect = .MultiDrawIndirect in capabilities,
			depthClamp = .DepthClamp in capabilities,
			depthBounds = .DepthBounds in capabilities,
			wideLines = .WideLines in capabilities,
			largePoints = .LargePoints in capabilities,
			multiViewport = .MultiViewport in capabilities,
			samplerAnisotropy = .SamplerAnisotropy in capabilities,
			shaderFloat64 = .ShaderFloat64 in capabilities,
			shaderInt64 = .ShaderInt64 in capabilities,
			shaderInt16 = .ShaderInt16 in capabilities,
			robustBufferAccess = .Robustness2 in capabilities,
		},
	}

	vk11Features := new(vk.PhysicalDeviceVulkan11Features, allocator, loc)
	vk11Features^ = {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		multiview            = .MultiView in capabilities,
		shaderDrawParameters = .ShaderDrawParameters in capabilities,
	}
	features2.pNext = vk11Features

	vk12Features := new(vk.PhysicalDeviceVulkan12Features, allocator, loc)
	vk12Features^ = {
		sType                                              = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		drawIndirectCount                                  = .DrawIndirectCount in capabilities,
		shaderFloat16                                      = .ShaderFloat16 in capabilities,
		shaderInt8                                         = .ShaderInt8 in capabilities,
		descriptorIndexing                                 = .DescriptorIndexing in capabilities,
		descriptorBindingUniformBufferUpdateAfterBind      = .DescriptorIndexing in capabilities,
		descriptorBindingSampledImageUpdateAfterBind       = .DescriptorIndexing in capabilities,
		descriptorBindingStorageImageUpdateAfterBind       = .DescriptorIndexing in capabilities,
		descriptorBindingStorageBufferUpdateAfterBind      = .DescriptorIndexing in capabilities,
		descriptorBindingUniformTexelBufferUpdateAfterBind = .DescriptorIndexing in capabilities,
		descriptorBindingStorageTexelBufferUpdateAfterBind = .DescriptorIndexing in capabilities,
		descriptorBindingUpdateUnusedWhilePending          = .DescriptorIndexing in capabilities,
		descriptorBindingPartiallyBound                    = .DescriptorIndexing in capabilities,
		runtimeDescriptorArray                             = .DescriptorIndexing in capabilities,
		descriptorBindingVariableDescriptorCount           = .VariableDescriptorCount in capabilities,
		timelineSemaphore                                  = .TimelineSemaphore in capabilities,
		bufferDeviceAddress                                = .BufferDeviceAddress in capabilities,
		scalarBlockLayout                                  = .ScalarBlockLayout in capabilities,
	}
	vk11Features.pNext = vk12Features

	vk13Features := new(vk.PhysicalDeviceVulkan13Features, allocator, loc)
	vk13Features^ = {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = .Synchronization2 in capabilities,
		dynamicRendering = .DynamicRendering in capabilities,
		maintenance4     = .Maintenance4 in capabilities,
	}
	vk12Features.pNext = vk13Features

	pNext: ^vk.BaseInStructure = auto_cast vk13Features

	if .SubgroupRotate in capabilities {
		subgroupRotateFeatures := new(vk.PhysicalDeviceShaderSubgroupRotateFeaturesKHR, allocator, loc)
		subgroupRotateFeatures^ = {
			sType                         = .PHYSICAL_DEVICE_SHADER_SUBGROUP_ROTATE_FEATURES_KHR,
			shaderSubgroupRotate          = .SubgroupRotate in capabilities,
			shaderSubgroupRotateClustered = .SubgroupRotate in capabilities,
		}
		pNext.pNext = auto_cast subgroupRotateFeatures
		pNext = auto_cast subgroupRotateFeatures
	}

	if .DynamicLocalRead in capabilities {
		dynamicLocalReadFeatures := new(vk.PhysicalDeviceDynamicRenderingLocalReadFeaturesKHR, allocator, loc)
		dynamicLocalReadFeatures^ = {
			sType                     = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR,
			dynamicRenderingLocalRead = .DynamicLocalRead in capabilities,
		}
		pNext.pNext = auto_cast dynamicLocalReadFeatures
		pNext = auto_cast dynamicLocalReadFeatures
	}

	if .AtomicAddFloat32Buffer in capabilities {
		atomicFloatFeatures := new(vk.PhysicalDeviceShaderAtomicFloatFeaturesEXT, allocator, loc)
		atomicFloatFeatures^ = {
			sType                        = .PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT,
			shaderBufferFloat32AtomicAdd = .AtomicAddFloat32Buffer in capabilities,
		}
		pNext.pNext = auto_cast atomicFloatFeatures
		pNext = auto_cast atomicFloatFeatures
	}

	if .SwapchainMaintenance in capabilities {
		swapchainMaintenance := new(vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT, allocator, loc)
		swapchainMaintenance^ = {
			sType                 = .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT,
			swapchainMaintenance1 = .SwapchainMaintenance in capabilities,
		}
		pNext.pNext = auto_cast swapchainMaintenance
		pNext = auto_cast swapchainMaintenance
	}

	if .ShaderObject in capabilities {
		shaderObject := new(vk.PhysicalDeviceShaderObjectFeaturesEXT, allocator, loc)
		shaderObject^ = {
			sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
			shaderObject = .ShaderObject in capabilities,
		}
		pNext.pNext = auto_cast shaderObject
		pNext = auto_cast shaderObject
	}

	if .FifoLatestReady in capabilities {
		presentModeFifoLatestReady := new(vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesEXT, allocator, loc)
		presentModeFifoLatestReady^ = {
			sType                      = .PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_EXT,
			presentModeFifoLatestReady = .FifoLatestReady in capabilities,
		}
		pNext.pNext = auto_cast presentModeFifoLatestReady
		pNext = auto_cast presentModeFifoLatestReady
	}

	if .MeshShader in capabilities {
		meshShader := new(vk.PhysicalDeviceMeshShaderFeaturesEXT, allocator, loc)
		meshShader^ = {
			sType      = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
			meshShader = .MeshShader in capabilities,
			taskShader = .TaskShader in capabilities,
		}
		pNext.pNext = auto_cast meshShader
		pNext = auto_cast meshShader
	}

	if .Robustness2 in capabilities {
		robustness2 := new(vk.PhysicalDeviceRobustness2FeaturesEXT, allocator, loc)
		robustness2^ = {
			sType               = .PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
			robustBufferAccess2 = .Robustness2 in capabilities,
			robustImageAccess2  = .Robustness2 in capabilities,
			nullDescriptor      = .Robustness2 in capabilities,
		}
		pNext.pNext = auto_cast robustness2
		pNext = auto_cast robustness2
	}

	if .Barycentric in capabilities {
		barycentric := new(vk.PhysicalDeviceFragmentShaderBarycentricFeaturesKHR, allocator, loc)
		barycentric^ = {
			sType                     = .PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR,
			fragmentShaderBarycentric = .Barycentric in capabilities,
		}
		pNext.pNext = auto_cast barycentric
		pNext = auto_cast barycentric
	}
	return
}

delete_device_features :: proc(features2: vk.PhysicalDeviceFeatures2, allocator := context.allocator) {
	cur: ^vk.BaseInStructure
	for pNext: ^vk.BaseInStructure = auto_cast features2.pNext;; pNext = pNext.pNext {
		if cur != nil do free(cur, allocator)
		if pNext == nil do break
		cur = pNext
	}
	if cur != nil do free(cur, allocator)
}

add_capability_extensions :: proc(extensions: ^[dynamic]cstring, capabilities: DeviceCapabilities) {
	featureExtensions := DEVICE_FEATURE_EXTENSIONS
	for feature in capabilities {
		for extension in featureExtensions[feature] {
			append(extensions, strings.clone_to_cstring(extension, context.temp_allocator))
		}
	}
}

@(require_results)
pick_physical_device :: proc(instance: vk.Instance, devices: #soa[]PhysicalDevice, criteria: DeviceCriteria) -> (chosenDevice: PhysicalDevice, ok: bool) {
	if len(devices) == 0 { ok = false; return }

	bestDeviceScore := 0

	for &device in devices {
		d := device
		if score := scorePhysicalDevice(&d, criteria); score > bestDeviceScore {
			chosenDevice = d
			bestDeviceScore = score
		}
		device = d
	}

	ok = bestDeviceScore > 0
	return

	scorePhysicalDevice :: proc(device: ^PhysicalDevice, criteria: DeviceCriteria) -> (score: int) {
		name := byte_arr_str(&device.properties.deviceName) // Can't I use cString -> string casting?
		log_debug_infof("vulkan: evaluating device %q", name)
		defer log_debug_infof("vulkan: device %q scored %v", name, score)

		// Check Required Capabilities
		{
			if unavailableRequiredCapabilities := criteria.requiredCapabilities - device.capabilities; unavailableRequiredCapabilities != {} {
				log_debug_infof("vulkan: device %q does not support required capabilities %q", name, unavailableRequiredCapabilities)
				return 0
			}

			optionalCapabilitiesWeight :: 10
			unavailableOptionalCapabilities := criteria.optionalCapabilities - device.capabilities
			if unavailableOptionalCapabilities != {} {
				log_debug_infof("vulkan: device %q does not support optional capabilities %q", name, unavailableOptionalCapabilities)
			}
			score -= optionalCapabilitiesWeight * int(intrinsics.count_ones(transmute(u64)(unavailableOptionalCapabilities)))
		}

		if criteria.graphics {
			canDraw := slice.any_of_proc(device.queueFamilies, proc(family: QueueFamily) -> bool {
				return .Graphics in family.properties
			})

			if !canDraw {
				log_debug_infof("vulkan: device %q does not have a queue family that supports graphics", name)
				return 0
			}
		}

		if criteria.present {
			if .Swapchain not_in device.capabilities {
				log_debug_infof("vulkan: device %q can not present as it does not have swapchain support", name)
				return 0
			}

			canPresent := slice.any_of_proc(device.queueFamilies, proc(family: QueueFamily) -> bool {
				return .Present in family.properties
			})

			if !canPresent {
				log_debug_infof("vulkan: device %q does not have a queue family that supports presenting", name)
				return 0
			}
		}

		// Favor GPUs.
		switch device.properties.deviceType {
		case .DISCRETE_GPU:
			score += 300_000
		case .INTEGRATED_GPU:
			score += 200_000
		case .VIRTUAL_GPU:
			score += 100_000
		case .CPU, .OTHER:
		}
		log_debug_infof("vulkan: scored %i based on device type %v", score, device.properties.deviceType)

		// Maximum texture size.
		score += int(device.properties.limits.maxImageDimension2D)
		log_debug_infof("vulkan: added the max 2D image dimensions (texture size) of %v to the score", device.properties.limits.maxImageDimension2D)
		return
	}
}

CheckPresentSupport :: #force_inline proc(physicalDevice: vk.PhysicalDevice, familyIndex: int) -> b32 {
	when ODIN_OS == .Windows {
		return vk.GetPhysicalDeviceWin32PresentationSupportKHR(physicalDevice, u32(familyIndex))
	} else {
		ekhos_util.throw_not_implemented()
		return false
	}
}

query_swapchain_support :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	allocator := context.allocator,
) -> (
	support: SwapchainSupport,
	result: vk.Result,
) {
	// NOTE: looks like a wrong binding with the third arg being a multipointer.
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &support.capabilities) or_return

	{
		count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, nil) or_return

		support.formats = make([]vk.SurfaceFormatKHR, count, allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, raw_data(support.formats)) or_return
	}

	{
		count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, nil) or_return

		support.presentModes = make([]vk.PresentModeKHR, count, allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &count, raw_data(support.presentModes)) or_return
	}

	result = .SUCCESS
	return
}

find_best_queue_family :: proc(queueFamilies: []QueueFamily, request: QueueRequest) -> (familyIndex: u32, count: u32) {
	minScore: u8 = bits.U8_MAX
	for family, index in queueFamilies {
		if !(family.properties > request.requiredProperties) do continue
		if family.queueCount == 0 do continue
		typeScore :=
			transmute(u8)intrinsics.count_ones(request.preferredProperties - family.properties) +
			transmute(u8)intrinsics.count_ones(request.unpreferredProperties & family.properties)
		if typeScore < minScore {
			familyIndex = auto_cast index
			minScore = typeScore
			count = min(family.queueCount, request.count)
		}
		if minScore == 0 do return
	}
	return
}

get_family_properties_from_flags :: proc(flags: vk.QueueFlags) -> (properties: QueueProperties) {
	if .COMPUTE in flags { properties |= {.Compute} }
	if .TRANSFER in flags { properties |= {.Transfer} }
	if .GRAPHICS in flags { properties |= {.Graphics} }
	if .VIDEO_DECODE_KHR in flags { properties |= {.VideoDecode} }
	if .VIDEO_ENCODE_KHR in flags { properties |= {.VideoEncode} }
	return
}

choose_swap_surface_format :: proc(formats: []vk.SurfaceFormatKHR, criteria: SwapCriteria) -> (surfaceFormat: vk.SurfaceFormatKHR, ok: bool) {
	if criteria.supportHdr {
		log.panic("TODO: Support HDR")
	}

	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format, true
		}
	}
	if (len(formats) > 0) {
		return formats[0], true
	}
	return
}

choose_swap_present_mode :: proc(presentModes: []vk.PresentModeKHR, criteria: SwapCriteria) -> vk.PresentModeKHR {
	// Uncapped framerate via Triple Buffering
	if criteria.uncappedFrameRate {
		for presentMode in presentModes {
			if presentMode == .MAILBOX {
				return presentMode
			}
		}
	}

	// Allows for higher frequency updates
	// TODO: need to enable VK_EXT_present_mode_fifo_latest_ready
	// May cause tearing, but prevents large frame drops, if we miss the blanking period
	if criteria.supportsFifoLatestReady {
		for presentMode in presentModes {
			if presentMode == .FIFO_LATEST_READY_EXT {
				return presentMode
			}
		}
	}

	// VSync, frames can be missed, one update per display refresh
	return .FIFO
}

choose_swap_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR, criteria: SwapCriteria) -> vk.Extent2D {
	// Use the extent provided by the window
	if (capabilities.currentExtent.width != bits.U32_MAX) {
		return capabilities.currentExtent
	} else { 	// Estimate the best extent to use within capabilities
		return {
			width = clamp(criteria.framebufferSize.x, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
			height = clamp(criteria.framebufferSize.y, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
		}
	}
}

/* ------------------ */
/* ----- Memory ----- */
/* ------------------ */

find_memory_type_proc :: #type proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool)

// Finds memory for long term use on the GPU, with minimal direct interaction with the CPU.
find_private_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.DEVICE_LOCAL}
	unpreferrredProperties += {.HOST_VISIBLE}
	#partial switch physicalDevice.properties.deviceType {
	case .INTEGRATED_GPU:
		requiredProperties -= {.DEVICE_LOCAL}
		preferrredProperties += {.DEVICE_LOCAL}
	}
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

// Finds memory suitable for constant CPU -> GPU upload and/or dynamic/transient GPU use. Typically corresponds to (Re)BAR Memory if it exists.
find_streaming_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.DEVICE_LOCAL, .HOST_VISIBLE} // BAR Memory is characterized by being host visible despite being on the device
	preferrredProperties += {.HOST_COHERENT} // Host visible memory is basically always host coherent, but we should avoid the few exceptions
	unpreferrredProperties += {.HOST_CACHED} // Caching behaviour will be counterproductive for streaming
	#partial switch physicalDevice.properties.deviceType {
	case .INTEGRATED_GPU:
		requiredProperties -= {.DEVICE_LOCAL}
		preferrredProperties += {.DEVICE_LOCAL} // Arguable whether we should target device local memory on a iGPU, but as long as these are allocated after dedicated allocations it's not a big deal
	}
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

// Finds memory suitable for CPU -> GPU staging.
find_staging_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.HOST_VISIBLE} // Memory of this type must be host visible
	preferrredProperties += {.HOST_COHERENT} // Host visible memory is basically always host coherent, but we should avoid the few exceptions
	unpreferrredProperties += {.HOST_CACHED, .DEVICE_LOCAL} // Caching isn't necessary for sequential writing and will only reduce performance.
	// Even if we can find device local memory that satisifies this, we shouldn't waste it on a staging buffer that doesn't need it
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

// Finds memory suitable for GPU -> CPU readback.
find_readback_memory_type :: proc(physicalDevice: PhysicalDevice, memoryRequirements: vk.MemoryRequirements) -> (typeIndex: u32, ok: bool) {
	requiredProperties, preferrredProperties, unpreferrredProperties: vk.MemoryPropertyFlags
	requiredProperties += {.HOST_VISIBLE, .HOST_CACHED} // Memory of this type must be host visible, and for fast random access it is practically necessary that is is host cached
	preferrredProperties += {.HOST_COHERENT} // Host visible memory is basically always host coherent, but we should avoid the few exceptions

	#partial switch physicalDevice.properties.deviceType {
	case .INTEGRATED_GPU:
		// APUs' device local heaps are often only 256 MB
		// We shouldn't waste memory on readback uses
		unpreferrredProperties += {.DEVICE_LOCAL}
	}
	return find_best_memory_type(physicalDevice, memoryRequirements, requiredProperties, preferrredProperties, unpreferrredProperties)
}

find_best_memory_type :: proc(
	physicalDevice: PhysicalDevice,
	memoryRequirements: vk.MemoryRequirements,
	requiredProperties: vk.MemoryPropertyFlags = {},
	preferrredProperties: vk.MemoryPropertyFlags = {},
	unpreferrredProperties: vk.MemoryPropertyFlags = {},
) -> (
	typeIndex: u32 = bits.U32_MAX,
	ok := false,
) {
	budget, usage := get_memory_budget(physicalDevice)
	minScore: u32 = bits.U32_MAX
	for memoryType, index in physicalDevice.memoryTypes {
		if bits.bitfield_extract(memoryRequirements.memoryTypeBits, auto_cast index, 1) == 1 &&
		   requiredProperties <= memoryType.propertyFlags &&
		   budget[memoryType.heapIndex] - usage[memoryType.heapIndex] >= memoryRequirements.size + (memoryRequirements.alignment - 1) {
			ok = true
			typeScore :=
				transmute(u32)intrinsics.count_ones(preferrredProperties - memoryType.propertyFlags) +
				transmute(u32)intrinsics.count_ones(unpreferrredProperties & memoryType.propertyFlags)
			if typeScore < minScore {
				typeIndex = auto_cast index
				minScore = typeScore
			}
			if minScore == 0 do return
		}
	}
	return
}

get_memory_budget :: proc(physicalDevice: PhysicalDevice) -> (budget, usage: [dynamic; vk.MAX_MEMORY_HEAPS]vk.DeviceSize) {
	budgetInfo: vk.PhysicalDeviceMemoryBudgetPropertiesEXT = {
		sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
	}
	memoryProperties: vk.PhysicalDeviceMemoryProperties2 = {
		sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
		pNext = &budgetInfo,
	}
	vk.GetPhysicalDeviceMemoryProperties2(physicalDevice.physicalDevice, &memoryProperties)
	append(&budget, ..budgetInfo.heapBudget[:len(physicalDevice.memoryHeaps)])
	append(&usage, ..budgetInfo.heapUsage[:len(physicalDevice.memoryHeaps)])
	return
}

get_memory_properties :: proc(physicalDevice: PhysicalDevice, memoryType: u32) -> vk.MemoryPropertyFlags {
	return physicalDevice.memoryTypes[memoryType].propertyFlags
}

DYNAMIC_GPU_ARENA_STARTING_ALLOCATION_SIZE :: 256 * runtime.Megabyte
DYNAMIC_GPU_ARENA_BLOCK_COUNT :: 16
DYNAMIC_GPU_ARENA_GROW_RATE :: 1.25
DYNAMIC_GPU_ARENA_MAX_ALLOCATION_SIZE :: 2 * runtime.Gigabyte

DynamicGpuArena :: struct {
	label:            string,
	device:           Device,
	memoryTypes:      [dynamic; vk.MAX_MEMORY_TYPES]u32,
	blocks:           [dynamic; DYNAMIC_GPU_ARENA_BLOCK_COUNT]Memory,
	offsets:          [dynamic; DYNAMIC_GPU_ARENA_BLOCK_COUNT]vk.DeviceSize,
	currentBlockSize: vk.DeviceSize,
}

dynamic_gpu_arena_init :: proc(device: Device, memoryTypes: [dynamic; vk.MAX_MEMORY_TYPES]u32, label := "") -> (arena: DynamicGpuArena, ok := true) {
	assert(device.device != {})
	check(len(memoryTypes) > 0) or_return
	checkLabel(label)
	arena = {
		label            = label,
		device           = device,
		memoryTypes      = memoryTypes,
		currentBlockSize = DYNAMIC_GPU_ARENA_STARTING_ALLOCATION_SIZE,
	}
	return
}

dynamic_gpu_arena_allocate_by_requirements :: proc(
	arena: ^DynamicGpuArena,
	requirements: vk.MemoryRequirements,
) -> (
	memory: Memory,
	offset: vk.DeviceSize,
	result := vk.Result.ERROR_OUT_OF_DEVICE_MEMORY,
) {
	return dynamic_gpu_arena_allocate(arena, requirements.size, requirements.alignment, requirements.memoryTypeBits)
}

dynamic_gpu_arena_allocate :: proc(
	arena: ^DynamicGpuArena,
	size, alignment: vk.DeviceSize,
	validMemoryTypes: u32 = bits.U32_MAX,
) -> (
	memory: Memory,
	offset: vk.DeviceSize,
	result: vk.Result,
) {
	assert(size <= DYNAMIC_GPU_ARENA_MAX_ALLOCATION_SIZE)
	for index in 0 ..< len(arena.blocks) {
		memory = arena.blocks[index]
		if bits.bitfield_extract(validMemoryTypes, auto_cast memory.type, 1) != 1 do continue
		offset = auto_cast runtime.align_forward(cast(uint)arena.offsets[index], cast(uint)alignment)
		if memory.size >= size + offset {
			arena.offsets[index] = offset + size
			return
		}
	}

	if len(arena.blocks) < cap(arena.blocks) {
		for mt in arena.memoryTypes {
			if bits.bitfield_extract(validMemoryTypes, auto_cast mt, 1) != 1 do continue
			label: string
			if len(arena.label) > 0 {
				label = fmt.tprintf("%s Block #%d", arena.label, len(arena.blocks))
			}
			memory = allocate_memory(arena.device, mt, arena.currentBlockSize, label) or_continue
			arena.currentBlockSize = cast(vk.DeviceSize)min(
				cast(f32)arena.currentBlockSize * DYNAMIC_GPU_ARENA_GROW_RATE,
				DYNAMIC_GPU_ARENA_MAX_ALLOCATION_SIZE,
			)
			append(&arena.blocks, memory)
			append(&arena.offsets, size)
			return
		}
	}
	return {}, {}, vk.Result.ERROR_OUT_OF_DEVICE_MEMORY
}

dynamic_gpu_arena_clear :: proc(arena: ^DynamicGpuArena) {
	for &offset in arena.offsets {
		offset = 0
	}
}

dynamic_gpu_arena_free :: proc(arena: ^DynamicGpuArena) {
	for &block in arena.blocks {
		// if .HOST_VISIBLE in get_memory_properties(arena.device.physicalDevice, block.memoryTypeIndex) {
		// 	vk.UnmapMemory(arena.device.device, block.memory)
		// }
		vk.FreeMemory(arena.device.device, block.memory, nil)
	}
	clear(&arena.blocks)
	arena.currentBlockSize = DYNAMIC_GPU_ARENA_STARTING_ALLOCATION_SIZE
}

/* --------------------- */
/* ----- Resources ----- */
/* --------------------- */

// Get Resource Memory Management
get_memory_requirements :: proc {
	get_memory_requirements_buffer,
	get_memory_requirements_image,
}

get_memory_requirements_buffer :: proc(device: Device, buffer: Buffer) -> (memoryRequirements: vk.MemoryRequirements) {
	vk.GetBufferMemoryRequirements(device.device, buffer.buffer, &memoryRequirements)
	return
}

get_memory_requirements_image :: proc(device: Device, image: Image) -> (memoryRequirements: vk.MemoryRequirements) {
	vk.GetImageMemoryRequirements(device.device, image.image, &memoryRequirements)
	return
}

create_staging_buffer :: proc {
	create_staging_buffer_for_buffer,
	create_staging_buffer_for_image,
}

create_staging_buffer_for_buffer :: proc(arena: ^DynamicGpuArena, buffer: Buffer, label := "") -> (stagingBuffer: Buffer, result: vk.Result) {
	stagingBuffer = create_buffer(arena.device, buffer.size, {.TRANSFER_SRC}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &stagingBuffer) or_return
	return
}

create_staging_buffer_for_image :: proc(arena: ^DynamicGpuArena, image: Image, label := "") -> (stagingBuffer: Buffer, result: vk.Result) {
	stagingBuffer = create_buffer(arena.device, image.size, {.TRANSFER_SRC}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &stagingBuffer) or_return
	return
}

create_readback_buffer :: proc {
	create_readback_buffer_for_buffer,
	create_readback_buffer_for_image,
}

create_readback_buffer_for_buffer :: proc(arena: ^DynamicGpuArena, buffer: Buffer, label := "") -> (readbackBuffer: Buffer, result: vk.Result) {
	readbackBuffer = create_buffer(arena.device, buffer.size, {.TRANSFER_DST}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &readbackBuffer) or_return
	return
}

create_readback_buffer_for_image :: proc(arena: ^DynamicGpuArena, image: Image, label := "") -> (readbackBuffer: Buffer, result: vk.Result) {
	readbackBuffer = create_buffer(arena.device, image.size, {.TRANSFER_DST}, .EXCLUSIVE, label = label) or_return
	bind_buffer_to_dynamic_gpu_arena(arena, &readbackBuffer) or_return
	return
}

/* --------------------- */
/* ----- Commands ----- */
/* --------------------- */

WaitSemaphore :: struct {
	sempahore: vk.Semaphore,
	value:     u64,
}

wait_semaphores :: proc(
	device: Device,
	waitSemaphores: #soa[]WaitSemaphore,
	timeout: u64,
	flags: vk.SemaphoreWaitFlags = {},
	allocator := context.temp_allocator,
) -> vk.Result {
	waitInfo: vk.SemaphoreWaitInfo = {
		sType          = .SEMAPHORE_WAIT_INFO,
		pNext          = nil,
		flags          = {},
		semaphoreCount = u32(len(waitSemaphores)),
		pSemaphores    = waitSemaphores.sempahore,
		pValues        = waitSemaphores.value,
	}
	return vk.WaitSemaphores(device.device, &waitInfo, timeout)
}

read_from_buffer :: proc(buffer: Buffer, data: []byte, regions: []vk.BufferCopy2 = {}) {
	assert(.HOST_VISIBLE in buffer.memory.properties && .HOST_COHERENT in buffer.memory.properties)
	assume(.HOST_CACHED not_in buffer.memory.properties)

	regions := regions
	if len(regions) == 0 {
		regions = {{sType = .BUFFER_COPY_2, size = min(vk.DeviceSize(len(data)), buffer.size)}}
	}

	for region in regions {
		copy(data[region.dstOffset:][:region.size], get_buffer_mapped_data(buffer)[region.srcOffset:][:region.size])
	}
}

cmd_begin :: proc(commandBuffer: CommandBuffer, oneTime := true) -> vk.Result {
	beginInfo: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = oneTime ? {.ONE_TIME_SUBMIT} : {},
	}
	return vk.BeginCommandBuffer(commandBuffer.commandBuffer, &beginInfo)
}

cmd_end :: proc(commandBuffer: CommandBuffer) -> vk.Result {
	return vk.EndCommandBuffer(commandBuffer.commandBuffer)
}

cmd_begin_label :: proc(commandBuffer: CommandBuffer, label: string, color: [4]f32 = {0, 0, 0, 0}) {
	if !commandBuffer.debugUtils do return
	labelInfo: vk.DebugUtilsLabelEXT = {
		sType      = .DEBUG_UTILS_LABEL_EXT,
		pLabelName = strings.clone_to_cstring(label, context.temp_allocator),
		color      = color,
	}
	vk.CmdBeginDebugUtilsLabelEXT(commandBuffer.commandBuffer, &labelInfo)
}

cmd_end_label :: proc(commandBuffer: CommandBuffer) {
	if commandBuffer.debugUtils do vk.CmdEndDebugUtilsLabelEXT(commandBuffer.commandBuffer)
}

cmd_write_timestamp :: proc(
	commandBuffer: CommandBuffer,
	queryPool: vk.QueryPool,
	query: u32,
	pipelineStage: vk.PipelineStageFlags = {.COMPUTE_SHADER},
) {
	vk.CmdWriteTimestamp(commandBuffer.commandBuffer, pipelineStage, queryPool, query)
}

cmd_reset_query_pool :: proc(commandBuffer: CommandBuffer, queryPool: vk.QueryPool, queryCount: u32) {
	vk.CmdResetQueryPool(commandBuffer.commandBuffer, queryPool, 0, queryCount)
}

SemaphoreBarrier :: struct {
	semaphore: Semaphore,
	value:     u64,
	stageMask: vk.PipelineStageFlags2,
}

queue_submit :: proc(queue: Queue, commandBuffers: []CommandBuffer, waits, signals: []SemaphoreBarrier, fence: vk.Fence = {}) -> vk.Result {
	queue := queue; context.user_ptr = &queue
	submitInfo: vk.SubmitInfo2 = {
		sType                    = .SUBMIT_INFO_2,
		commandBufferInfoCount   = auto_cast len(commandBuffers),
		pCommandBufferInfos      = raw_data(slice.mapper(commandBuffers, commandBufferMapper, context.temp_allocator)),
		waitSemaphoreInfoCount   = auto_cast len(waits),
		pWaitSemaphoreInfos      = raw_data(slice.mapper(waits, semaphoreMapper, context.temp_allocator)),
		signalSemaphoreInfoCount = auto_cast len(signals),
		pSignalSemaphoreInfos    = raw_data(slice.mapper(signals, semaphoreMapper, context.temp_allocator)),
	}
	return vk.QueueSubmit2(queue.queue, 1, &submitInfo, fence)

	commandBufferCheck :: proc(commandBuffer: CommandBuffer, queue: Queue) -> bool {
		return commandBuffer.queueFamilyIndex == queue.familyIndex
	}
	commandBufferMapper :: proc(commandBuffer: CommandBuffer) -> vk.CommandBufferSubmitInfo {
		assert(commandBuffer.queueFamilyIndex == (cast(^Queue)context.user_ptr).familyIndex)
		return {sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = commandBuffer.commandBuffer}
	}
	semaphoreMapper :: proc(barrier: SemaphoreBarrier) -> vk.SemaphoreSubmitInfo {
		#no_type_assert {
			return {
				sType = .SEMAPHORE_SUBMIT_INFO,
				semaphore = auto_cast barrier.semaphore.(TimelineSemaphore),
				value = barrier.value,
				stageMask = barrier.stageMask,
			}
		}
	}
}

cmd_transition :: proc(commandBuffer: CommandBuffer, transition: vk.ImageMemoryBarrier2) {
	cmd_pipeline_barrier(commandBuffer, imageBarriers = {transition})
}

cmd_pipeline_barrier :: proc(
	commandBuffer: CommandBuffer,
	memoryBarriers: []vk.MemoryBarrier2 = {},
	bufferBarriers: []vk.BufferMemoryBarrier2 = {},
	imageBarriers: []vk.ImageMemoryBarrier2 = {},
) {
	dependencyInfo := make_dependency_info(memoryBarriers, bufferBarriers, imageBarriers)
	vk.CmdPipelineBarrier2(commandBuffer.commandBuffer, &dependencyInfo)
}

cmd_upload :: proc {
	cmd_upload_to_buffer,
	cmd_upload_to_image,
}

cmd_upload_to_buffer :: proc(commandBuffer: CommandBuffer, data: []byte, buffer: Buffer, stagingBuffer: Buffer = {}, regions: []vk.BufferCopy2 = {}) {
	regions := regions
	if len(regions) == 0 {
		regions = {{sType = .BUFFER_COPY_2, size = min(vk.DeviceSize(len(data)), buffer.size)}}
	}

	staged := !buffer_is_mapped(buffer)
	if staged do assert(buffer_is_mapped(stagingBuffer))

	mappedBuffer := (!staged) ? buffer : stagingBuffer
	assert(.HOST_COHERENT in mappedBuffer.memory.properties)
	assume(.HOST_CACHED not_in mappedBuffer.memory.properties)

	for region in regions {
		copy(get_buffer_mapped_data(mappedBuffer)[region.dstOffset:][:region.size], data[region.srcOffset:][:region.size])
	}

	if staged {
		copyInfo: vk.CopyBufferInfo2 = {
			sType       = .COPY_BUFFER_INFO_2,
			srcBuffer   = stagingBuffer.buffer,
			dstBuffer   = buffer.buffer,
			regionCount = u32(len(regions)),
			pRegions    = raw_data(regions),
		}
		vk.CmdCopyBuffer2(commandBuffer.commandBuffer, &copyInfo)
	}
}

cmd_copy_buffer :: proc(commandBuffer: CommandBuffer, source, destination: Buffer, regions: []vk.BufferCopy2) {
	copyInfo: vk.CopyBufferInfo2 = {
		sType       = .COPY_BUFFER_INFO_2,
		srcBuffer   = source.buffer,
		dstBuffer   = destination.buffer,
		regionCount = u32(len(regions)),
		pRegions    = raw_data(regions),
	}
	vk.CmdCopyBuffer2(commandBuffer.commandBuffer, &copyInfo)
}

cmd_upload_to_image :: proc(commandBuffer: CommandBuffer, data: []byte, image: Image, stagingBuffer: Buffer) {
	assert(image.size == vk.DeviceSize(len(data)))
	assert(.HOST_VISIBLE in stagingBuffer.memory.properties && .HOST_COHERENT in stagingBuffer.memory.properties)
	assume(.HOST_CACHED not_in stagingBuffer.memory.properties)

	copy(get_buffer_mapped_data(stagingBuffer)[:len(data)], data)

	regionInfo: vk.BufferImageCopy2 = {
		sType = .BUFFER_IMAGE_COPY_2,
		imageExtent = image.extent,
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
	}
	copyInfo: vk.CopyBufferToImageInfo2 = {
		sType          = .COPY_BUFFER_TO_IMAGE_INFO_2,
		srcBuffer      = stagingBuffer.buffer,
		dstImage       = image.image,
		dstImageLayout = .TRANSFER_DST_OPTIMAL,
		regionCount    = 1,
		pRegions       = &regionInfo,
	}

	vk.CmdCopyBufferToImage2(commandBuffer.commandBuffer, &copyInfo)
}

cmd_download :: proc {
	cmd_download_from_buffer,
	cmd_download_from_image,
}

cmd_download_from_buffer :: proc(commandBuffer: CommandBuffer, buffer, readbackBuffer: Buffer, regions: []vk.BufferCopy2 = {}) {
	assert(is_mapped(readbackBuffer))
	assert(.HOST_VISIBLE in readbackBuffer.memory.properties && .HOST_COHERENT in readbackBuffer.memory.properties)
	assume(.HOST_CACHED in readbackBuffer.memory.properties)

	regions := regions
	if len(regions) == 0 {
		regions = {{sType = .BUFFER_COPY_2, size = min(buffer.size, readbackBuffer.size)}}
	}

	copyInfo: vk.CopyBufferInfo2 = {
		sType       = .COPY_BUFFER_INFO_2,
		srcBuffer   = buffer.buffer,
		dstBuffer   = readbackBuffer.buffer,
		regionCount = u32(len(regions)),
		pRegions    = raw_data(regions),
	}
	vk.CmdCopyBuffer2(commandBuffer.commandBuffer, &copyInfo)
}

cmd_download_from_image :: proc(commandBuffer: CommandBuffer, image: Image, readbackBuffer: Buffer) {
	assert(is_mapped(readbackBuffer))
	assert(.HOST_VISIBLE in readbackBuffer.memory.properties && .HOST_COHERENT in readbackBuffer.memory.properties)
	assume(.HOST_CACHED in readbackBuffer.memory.properties)

	regionInfo: vk.BufferImageCopy2 = {
		sType = .BUFFER_IMAGE_COPY_2,
		imageExtent = image.extent,
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
	}

	copyInfo: vk.CopyImageToBufferInfo2 = {
		sType          = .COPY_IMAGE_TO_BUFFER_INFO_2,
		srcImage       = image.image,
		srcImageLayout = .TRANSFER_SRC_OPTIMAL,
		dstBuffer      = readbackBuffer.buffer,
		regionCount    = 1,
		pRegions       = &regionInfo,
	}

	vk.CmdCopyImageToBuffer2(commandBuffer.commandBuffer, &copyInfo)
}

cmd_populate_mip :: proc(commandBuffer: CommandBuffer, image: Image) {
	unimplemented()
}

cmd_clear_buffer :: proc(commandBuffer: CommandBuffer, buffer: Buffer) {
	cmd_fill_buffer(commandBuffer, buffer, 0)
}

cmd_fill_buffer :: proc(commandBuffer: CommandBuffer, buffer: Buffer, value: u32) {
	vk.CmdFillBuffer(commandBuffer.commandBuffer, buffer.buffer, buffer.offset, buffer.size, value)
}
