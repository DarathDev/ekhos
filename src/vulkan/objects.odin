package ekhos_vulkan

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import win32 "core:sys/windows"
import vk "vendor:vulkan"
import ekhos_util "ekhos:utility"

@(private = "file")
assert :: ekhos_util.assert
@(private = "file")
check :: ekhos_util.check

REQUIRE_RESOURCE_LABELS :: #config(REQUIRE_RESOURCE_LABELS, ODIN_DEBUG)
@(thread_local)
EXCUSE_RESOURCE_LABELS: bool

/* -------------------- */
/* ----- Instance ----- */
/* -------------------- */

AppInfo :: struct {
	appName:              string,
	appVersion:           ekhos_util.SemanticVersion,
	engineName:           string,
	engineVersion:        ekhos_util.SemanticVersion,
	vulkanVersion:        u32,
	requiredCapabilities: InstanceCapabilities,
	optionalCapabilities: InstanceCapabilities,
}

InstanceCapability :: enum {
	Validation,
	Present,
	PresentWin32,
	PresentMetal,
	PresentXcb,
	PresentXLib,
	PresentWayland,
	DeviceAddressBindingReport,
	DebugUtils,
	Portability,
	ShaderObject, // TODO: Bundle ShaderObjectLayer with application
}

InstanceCapabilities :: bit_set[InstanceCapability]

Instance :: struct {
	instance:            vk.Instance,
	apiVersion:          u32,
	enabledCapabilities: InstanceCapabilities,
}

@(require_results)
create_instance :: proc(appInfo: AppInfo, debugUserData: ^DebugUserData = nil, allocator := context.allocator) -> (instance: Instance, result: vk.Result) {
	availableLayerCount: u32
	for result = check(vk.EnumerateInstanceLayerProperties(&availableLayerCount, nil)); result == .INCOMPLETE; {  }
	availableLayers := make([]vk.LayerProperties, availableLayerCount, context.temp_allocator)
	for result = check(vk.EnumerateInstanceLayerProperties(&availableLayerCount, raw_data(availableLayers))); result == .INCOMPLETE; {  }

	availableExtensionCount: u32
	for result = check(vk.EnumerateInstanceExtensionProperties(nil, &availableExtensionCount, nil)); result == .INCOMPLETE; {  }
	availableExtensions := make([]vk.ExtensionProperties, availableExtensionCount, context.temp_allocator)
	for result = check(vk.EnumerateInstanceExtensionProperties(nil, &availableExtensionCount, raw_data(availableExtensions))); result == .INCOMPLETE; {  }

	capabilities := deduce_instance_capabilities(availableLayers, availableExtensions)
	if !check(capabilities > appInfo.requiredCapabilities) { return {}, .ERROR_EXTENSION_NOT_PRESENT }
	instance.enabledCapabilities = appInfo.requiredCapabilities + (appInfo.optionalCapabilities & capabilities)

	if .Present in instance.enabledCapabilities { instance.enabledCapabilities += capabilities & PRESENT_SUBCAPABILITIES }

	when ODIN_OS == .Darwin {
		if !check(.Portability in capabilities) { return {}, .ERROR_EXTENSION_NOT_PRESENT }
		instance.enabledCapabilities += {.Portability}
	}

	enabledLayers := make_instance_layer_names(instance.enabledCapabilities, context.temp_allocator)
	enabledExtensions := make_instance_extension_names(instance.enabledCapabilities, context.temp_allocator)

	instanceCreateInfo := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pNext                   = nil,
		flags                   = make_instance_flags(instance.enabledCapabilities),
		pApplicationInfo        = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pNext = nil,
			pApplicationName = strings.clone_to_cstring(appInfo.appName, context.temp_allocator),
			applicationVersion = vk.MAKE_VERSION(auto_cast appInfo.appVersion.major, auto_cast appInfo.appVersion.minor, auto_cast appInfo.appVersion.patch),
			pEngineName = strings.clone_to_cstring(appInfo.engineName, context.temp_allocator),
			engineVersion = vk.MAKE_VERSION(
				auto_cast appInfo.engineVersion.major,
				auto_cast appInfo.engineVersion.minor,
				auto_cast appInfo.engineVersion.patch,
			),
			apiVersion = appInfo.vulkanVersion,
		},
		enabledLayerCount       = auto_cast len(enabledLayers),
		ppEnabledLayerNames     = raw_data(enabledLayers),
		enabledExtensionCount   = auto_cast len(enabledExtensions),
		ppEnabledExtensionNames = raw_data(enabledExtensions),
	}

	dbgInfo: ^vk.DebugUtilsMessengerCreateInfoEXT
	if .DebugUtils in instance.enabledCapabilities {
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error { severity |= {.ERROR} }
		if context.logger.lowest_level <= .Warning { severity |= {.WARNING} }
		if context.logger.lowest_level <= .Info { severity |= {.INFO} }
		if context.logger.lowest_level <= .Debug { severity |= {.VERBOSE} }

		messageType: vk.DebugUtilsMessageTypeFlagsEXT = {.GENERAL, .PERFORMANCE}
		if .Validation in instance.enabledCapabilities { messageType |= {.VALIDATION} }
		if .DeviceAddressBindingReport in instance.enabledCapabilities { messageType |= {.DEVICE_ADDRESS_BINDING} }

		dbgInfo = new(vk.DebugUtilsMessengerCreateInfoEXT, context.temp_allocator)
		dbgInfo^ = {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			pNext           = nil,
			messageSeverity = severity,
			messageType     = messageType,
			pfnUserCallback = vk_messenger_callback,
			pUserData       = debugUserData,
		}

		instanceCreateInfo.pNext = dbgInfo
	}

	check(vk.CreateInstance(&instanceCreateInfo, nil, &instance.instance)) or_return
	instance.apiVersion = appInfo.vulkanVersion
	vk.load_proc_addresses_instance(instance.instance)
	return
}

has_string :: proc(strs: []string, str: string) -> (result: bool) {
	result = true
	for test in strs {
		if strings.compare(test, str) == 0 {
			return
		}
	}
	return false
}

destroy_instance :: proc(instance: ^Instance) {
	vk.DestroyInstance(instance.instance, nil)
}

/* --------------------------- */
/* ----- Debug Messenger ----- */
/* --------------------------- */

DebugMessenger :: struct {
	debugMessenger: vk.DebugUtilsMessengerEXT,
	userData:       ^DebugUserData,
}

DebugUserData :: struct {
	logger: runtime.Logger,
}

@(require_results)
create_debug_messenger :: proc(instance: Instance, userData: ^DebugUserData, allocator := context.allocator) -> (dbgMsg: DebugMessenger, result: vk.Result) {
	if !check(.DebugUtils in instance.enabledCapabilities) do return {}, .ERROR_EXTENSION_NOT_PRESENT
	// Severity based on logger level.
	severity: vk.DebugUtilsMessageSeverityFlagsEXT
	if context.logger.lowest_level <= .Error { severity |= {.ERROR} }
	if context.logger.lowest_level <= .Warning { severity |= {.WARNING} }
	if context.logger.lowest_level <= .Info { severity |= {.INFO} }
	if context.logger.lowest_level <= .Debug { severity |= {.VERBOSE} }

	createInfo := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		pNext           = nil,
		messageSeverity = severity,
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = vk_messenger_callback,
		pUserData       = userData,
	}
	if .DeviceAddressBindingReport in instance.enabledCapabilities {
		createInfo.messageType |= {.DEVICE_ADDRESS_BINDING}
	}
	check(vk.CreateDebugUtilsMessengerEXT(instance.instance, &createInfo, nil, &dbgMsg.debugMessenger)) or_return
	return
}

destroy_debug_messenger :: proc(instance: vk.Instance, dbgMsg: ^DebugMessenger) {
	vk.DestroyDebugUtilsMessengerEXT(instance, dbgMsg.debugMessenger, nil)
}

/* ------------------- */
/* ----- Surface ----- */
/* ------------------- */


when ODIN_OS == .Windows {
	create_surface :: proc {
		create_win32_surface,
	}

	create_win32_surface :: proc(instance: Instance, window: win32.HWND, hInstance: win32.HINSTANCE) -> (surface: vk.SurfaceKHR, ok: vk.Result) {
		assert(.PresentWin32 in instance.enabledCapabilities)
		createInfo: vk.Win32SurfaceCreateInfoKHR = {
			sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
			flags     = {},
			hwnd      = window,
			hinstance = hInstance,
		}
		check(vk.CreateWin32SurfaceKHR(instance.instance, &createInfo, nil, &surface)) or_return
		return
	}

	destroy_surface :: proc(instance: vk.Instance, surface: vk.SurfaceKHR) {
		vk.DestroySurfaceKHR(instance, surface, nil)
	}
}

/* --------------------------- */
/* ----- Physical Device ----- */
/* --------------------------- */

DeviceCriteria :: struct {
	graphics:             bool,
	present:              bool,
	requiredCapabilities: DeviceCapabilities,
	optionalCapabilities: DeviceCapabilities,
}

DeviceCapability :: enum {
	// Vulkan 1.0 Features
	GeometryShaders,
	TessellationShaders,
	SampleRateShading,
	LogicOp,
	MultiDrawIndirect,
	DepthClamp,
	DepthBounds,
	WideLines,
	LargePoints,
	MultiViewport,
	SamplerAnisotropy,
	ShaderFloat64,
	ShaderInt64,
	ShaderInt16,
	// Vulkan 1.1 Features
	MultiView,
	ShaderDrawParameters,
	// Vulkan 1.2 Features
	DrawIndirectCount,
	ShaderFloat16,
	ShaderInt8,
	DescriptorIndexing,
	VariableDescriptorCount,
	TimelineSemaphore,
	BufferDeviceAddress,
	ScalarBlockLayout,
	// Vulkan 1.3 Features
	Synchronization2,
	DynamicRendering,
	Maintenance4,
	// Vulkan 1.4 Features
	SubgroupRotate,
	DynamicLocalRead,
	// Mesh Shaders
	TaskShader,
	MeshShader,
	// Swapchain Maintenance
	SwapchainMaintenance,
	// Shader Object
	ShaderObject,
	// Barycentric
	Barycentric,
	// Extensions
	AtomicAddFloat32Buffer,
	Swapchain,
	FifoLatestReady,
	ExternalMemoryHost,
	Robustness2,
}

DeviceCapabilities :: bit_set[DeviceCapability]

PhysicalDevice :: struct {
	name:             string,
	physicalDevice:   vk.PhysicalDevice,
	properties:       vk.PhysicalDeviceProperties,
	maxBufferSize:    vk.DeviceSize,
	capabilities:     DeviceCapabilities,
	queueFamilies:    []QueueFamily,
	memoryProperties: vk.PhysicalDeviceMemoryProperties,
	memoryHeaps:      [dynamic; vk.MAX_MEMORY_TYPES]vk.MemoryHeap,
	memoryTypes:      [dynamic; vk.MAX_MEMORY_HEAPS]vk.MemoryType,
}

@(require_results)
get_physical_devices :: proc(instance: Instance, allocator := context.allocator) -> (devices: #soa[]PhysicalDevice, result: vk.Result) {

	deviceCount: u32
	check(vk.EnumeratePhysicalDevices(instance.instance, &deviceCount, nil)) or_return
	devicesOk: mem.Allocator_Error
	devices, devicesOk = make(#soa[]PhysicalDevice, deviceCount, allocator)
	if devicesOk != .None {
		result = vk.Result.ERROR_OUT_OF_HOST_MEMORY
		return
	}
	check(vk.EnumeratePhysicalDevices(instance.instance, &deviceCount, devices.physicalDevice)) or_return

	features := make_device_features(~{}, context.temp_allocator)

	for &device in devices {
		vk.GetPhysicalDeviceProperties(device.physicalDevice, &device.properties)
		maintenance4Properties := vk.PhysicalDeviceMaintenance4Properties {
			sType = .PHYSICAL_DEVICE_MAINTENANCE_4_PROPERTIES,
		}
		properties2 := vk.PhysicalDeviceProperties2 {
			sType = .PHYSICAL_DEVICE_PROPERTIES_2,
			pNext = &maintenance4Properties,
		}
		vk.GetPhysicalDeviceProperties2(device.physicalDevice, &properties2)
		device.maxBufferSize = maintenance4Properties.maxBufferSize
		device.name = strings.clone_from_cstring_bounded(cast(cstring)&device.properties.deviceName[0], vk.MAX_PHYSICAL_DEVICE_NAME_SIZE, allocator)
		queueFamilyCount: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &queueFamilyCount, nil)
		queueFamiliesProperties := make([]vk.QueueFamilyProperties, queueFamilyCount, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(device.physicalDevice, &queueFamilyCount, raw_data(queueFamiliesProperties))
		device.queueFamilies = make([]QueueFamily, queueFamilyCount, allocator)
		for familyIndex in 0 ..< len(queueFamiliesProperties) {
			device.queueFamilies[familyIndex].queueCount = queueFamiliesProperties[familyIndex].queueCount
			device.queueFamilies[familyIndex].properties = get_family_properties_from_flags(queueFamiliesProperties[familyIndex].queueFlags)
		}
		if .Present in instance.enabledCapabilities {
			for &support, familyIndex in device.queueFamilies {
				if CheckPresentSupport(device.physicalDevice, familyIndex) { support.properties |= {.Present} }
			}
		}

		extensionCount: u32
		vk.GetPhysicalDeviceFeatures2(device.physicalDevice, &features)
		check(vk.EnumerateDeviceExtensionProperties(device.physicalDevice, nil, &extensionCount, nil)) or_return
		extensions := make([]vk.ExtensionProperties, extensionCount, context.temp_allocator)
		check(vk.EnumerateDeviceExtensionProperties(device.physicalDevice, nil, &extensionCount, raw_data(extensions))) or_return
		device.capabilities = deduce_device_capabilities(features, extensions)

		memoryProperties: vk.PhysicalDeviceMemoryProperties
		vk.GetPhysicalDeviceMemoryProperties(device.physicalDevice, &memoryProperties)
		clear(&device.memoryHeaps); clear(&device.memoryTypes)
		append(&device.memoryHeaps, ..memoryProperties.memoryHeaps[:memoryProperties.memoryHeapCount])
		append(&device.memoryTypes, ..memoryProperties.memoryTypes[:memoryProperties.memoryTypeCount])
	}
	return
}

free_physical_devices :: proc(devices: ^#soa[]PhysicalDevice, allocator := context.allocator) {
	for &device in devices {
		delete(device.queueFamilies, allocator)
		clear(&device.memoryHeaps)
		clear(&device.memoryTypes)
		delete(device.name, allocator)
	}
	delete(devices^, allocator)
}

/* ------------------ */
/* ----- Device ----- */
/* ------------------ */

Device :: struct {
	physicalDevice:       PhysicalDevice,
	device:               vk.Device,
	enabledCapabilities:  DeviceCapabilities,
	instanceCapabilities: InstanceCapabilities,
}

QueueProperty :: enum {
	Compute,
	Transfer,
	Graphics,
	Present,
	VideoDecode,
	VideoEncode,
}

QueueProperties :: bit_set[QueueProperty]

QueueFamily :: struct {
	queueCount: u32,
	properties: QueueProperties,
}

QueueRequest :: struct {
	count:                 u32,
	priority:              f32,
	requiredProperties:    QueueProperties,
	preferredProperties:   QueueProperties,
	unpreferredProperties: QueueProperties,
}

Queue :: struct {
	queue:       vk.Queue,
	properties:  QueueProperties,
	priority:    f32,
	familyIndex: u32,
	queueIndex:  u32,
}

@(require_results)
create_device :: proc(
	instance: Instance,
	physicalDevice: PhysicalDevice,
	criteria: DeviceCriteria,
	queueRequests: []QueueRequest,
	label := "",
	allocator := context.allocator,
) -> (
	device: Device,
	queues: [][]Queue,
	result: vk.Result,
) {
	checkLabel(label)
	context.allocator = allocator

	defer check(result != .SUCCESS || device.device != {})

	queueFamilies := slice.clone(physicalDevice.queueFamilies, context.temp_allocator)

	queues = make([][]Queue, len(queueRequests), allocator)
	currentQueueIndex := make([]u32, len(queueFamilies), context.temp_allocator)
	queuePriorities := make([][dynamic]f32, len(queueFamilies), context.temp_allocator)
	for &priority in queuePriorities {
		priority = make([dynamic]f32, context.temp_allocator)
	}
	totalQueueCount: u32
	for request, index in queueRequests {
		queues[index] = make([]Queue, request.count, allocator)
		for requestCount := 0; auto_cast requestCount < request.count; {
			bestFamily, count := find_best_queue_family(queueFamilies, request)
			if count == 0 do return {}, {}, .ERROR_TOO_MANY_OBJECTS
			for &queue, queueIndex in queues[index][requestCount:][:count] {
				queue = Queue {
					familyIndex = bestFamily,
					priority    = request.priority,
					properties  = queueFamilies[bestFamily].properties,
					queueIndex  = auto_cast queueIndex + currentQueueIndex[bestFamily],
				}
				append(&queuePriorities[bestFamily], request.priority)
			}
			requestCount += auto_cast count
			currentQueueIndex[bestFamily] += count
		}
		totalQueueCount += request.count
	}

	queueCreateInfos := make([dynamic]vk.DeviceQueueCreateInfo, context.temp_allocator)
	for count, familyIndex in currentQueueIndex {
		if count == 0 do continue
		append(
			&queueCreateInfos,
			vk.DeviceQueueCreateInfo {
				sType = .DEVICE_QUEUE_CREATE_INFO,
				pNext = nil,
				queueFamilyIndex = auto_cast familyIndex,
				queueCount = count,
				pQueuePriorities = raw_data(queuePriorities[familyIndex]),
			},
		)
	}

	device.enabledCapabilities = criteria.requiredCapabilities + (criteria.optionalCapabilities & physicalDevice.capabilities)
	enabledExtensions := make([dynamic]cstring, context.temp_allocator)
	add_capability_extensions(&enabledExtensions, device.enabledCapabilities)

	deviceFeatures := make_device_features(device.enabledCapabilities, context.temp_allocator)

	deviceCreateInfo: vk.DeviceCreateInfo = {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &deviceFeatures,
		enabledExtensionCount   = u32(len(enabledExtensions)),
		ppEnabledExtensionNames = raw_data(enabledExtensions),
		queueCreateInfoCount    = u32(len(queueCreateInfos)),
		pQueueCreateInfos       = raw_data(queueCreateInfos),
	}

	check(vk.CreateDevice(physicalDevice.physicalDevice, &deviceCreateInfo, nil, &device.device)) or_return
	name(device, label)
	device.physicalDevice = physicalDevice

	for request in queues {
		for &queue in request {
			vk.GetDeviceQueue(device.device, queue.familyIndex, queue.queueIndex, &queue.queue)
		}
	}
	device.instanceCapabilities = instance.enabledCapabilities
	return
}

destroy_device :: proc(device: ^Device) {
	vk.DestroyDevice(device.device, nil)
}

/* --------------------- */
/* ----- Swapchain ----- */
/* --------------------- */

SwapCriteria :: struct {
	supportHdr:              bool,
	uncappedFrameRate:       bool,
	framebufferSize:         [2]u32,
	supportsFifoLatestReady: bool,
}

SwapchainSupport :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}

Swapchain :: struct {
	allocator:     mem.Allocator,
	surface:       vk.SurfaceKHR,
	swapchain:     vk.SwapchainKHR,
	images:        #soa[dynamic]Image,
	views:         #soa[dynamic]ImageView,
	semaphores:    [dynamic]BinarySemaphore,
	surfaceFormat: vk.SurfaceFormatKHR,
	presentMode:   vk.PresentModeKHR,
	extent:        vk.Extent2D,
	support:       SwapchainSupport,
}

@(require_results)
create_swapchain :: proc(
	device: ^Device,
	surface: vk.SurfaceKHR,
	criteria: SwapCriteria,
	label: string = "",
	allocator := context.allocator,
) -> (
	swapchain: Swapchain,
	result: vk.Result,
) {
	checkLabel(label)
	defer check(result != .SUCCESS || swapchain.swapchain != {})
	defer check(result != .SUCCESS || swapchain.surface != {})

	swapchain.support = query_swapchain_support(device.physicalDevice.physicalDevice, surface, allocator) or_return
	surfaceFormat, formatOk := choose_swap_surface_format(swapchain.support.formats, criteria)
	presentMode := choose_swap_present_mode(swapchain.support.presentModes, criteria)
	extent := choose_swap_extent(swapchain.support.capabilities, criteria)
	check(formatOk)

	imageCount: u32 = swapchain.support.capabilities.minImageCount + 1
	if (swapchain.support.capabilities.maxImageCount > 0) {
		imageCount = min(imageCount, swapchain.support.capabilities.maxImageCount)
	}

	createInfo: vk.SwapchainCreateInfoKHR = {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		pNext            = nil,
		surface          = surface,
		minImageCount    = imageCount,
		imageFormat      = surfaceFormat.format,
		imageColorSpace  = surfaceFormat.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		preTransform     = swapchain.support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = presentMode,
		clipped          = false, // TODO: This might interfere with screenshotting, streaming etc. if true. Check with Vulkan spec
		imageSharingMode = .EXCLUSIVE,
		oldSwapchain     = {},
	}
	swapchain = {
		allocator     = allocator,
		surfaceFormat = surfaceFormat,
		extent        = extent,
		presentMode   = presentMode,
		surface       = surface,
	}

	make_swapchain(device^, &createInfo, &swapchain, label)
	return
}

recreate_swapchain :: proc(
	device: Device,
	oldSwapchain: Swapchain,
	criteria: SwapCriteria,
	label: string = "",
	allocator := context.allocator,
) -> (
	swapchain: Swapchain,
	result: vk.Result,
) {
	checkLabel(label)
	swapchain.support = query_swapchain_support(device.physicalDevice.physicalDevice, oldSwapchain.surface, allocator) or_return
	surfaceFormat, formatOk := check(choose_swap_surface_format(swapchain.support.formats, criteria))
	if !formatOk do return {}, .ERROR_FORMAT_NOT_SUPPORTED
	presentMode := choose_swap_present_mode(swapchain.support.presentModes, criteria)
	extent := choose_swap_extent(swapchain.support.capabilities, criteria)

	imageCount: u32 = swapchain.support.capabilities.minImageCount + 1
	if (swapchain.support.capabilities.maxImageCount > 0) {
		imageCount = min(imageCount, swapchain.support.capabilities.maxImageCount)
	}

	createInfo: vk.SwapchainCreateInfoKHR = {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		pNext            = nil,
		surface          = oldSwapchain.surface,
		minImageCount    = imageCount,
		imageFormat      = surfaceFormat.format,
		imageColorSpace  = surfaceFormat.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		preTransform     = swapchain.support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = presentMode,
		clipped          = false, // TODO: This might interfere with screenshotting, streaming etc. if true. Check with Vulkan spec
		imageSharingMode = .EXCLUSIVE,
		oldSwapchain     = oldSwapchain.swapchain,
	}
	swapchain = {
		allocator     = allocator,
		surfaceFormat = surfaceFormat,
		extent        = extent,
		presentMode   = presentMode,
		surface       = oldSwapchain.surface,
	}
	make_swapchain(device, &createInfo, &swapchain, label) or_return
	return
}

@(private)
make_swapchain :: proc(device: Device, createInfo: ^vk.SwapchainCreateInfoKHR, swapchain: ^Swapchain, label: string = "") -> (result: vk.Result) {

	check(swapchain.swapchain == {} || swapchain.swapchain == createInfo.oldSwapchain)
	defer check(len(swapchain.images) >= auto_cast createInfo.minImageCount)
	defer check(len(swapchain.images) == len(swapchain.views))
	defer check(len(swapchain.images) == len(swapchain.semaphores))

	for view in swapchain.views {
		destroy_image_view(device, view)
	}
	for semaphore in swapchain.semaphores {
		destroy_binary_semaphore(device, semaphore)
	}

	check(vk.CreateSwapchainKHR(device.device, createInfo, nil, &swapchain.swapchain)) or_return
	name(device, swapchain.swapchain, label)

	imageCount: u32
	check(vk.GetSwapchainImagesKHR(device.device, swapchain.swapchain, &imageCount, nil)) or_return
	swapchain.images = make(#soa[dynamic]Image, imageCount, swapchain.allocator)
	swapchain.views = make(#soa[dynamic]ImageView, imageCount, swapchain.allocator)
	swapchain.semaphores = make([dynamic]BinarySemaphore, imageCount, swapchain.allocator)
	check(vk.GetSwapchainImagesKHR(device.device, swapchain.swapchain, &imageCount, swapchain.images.image)) or_return
	for &image, index in swapchain.images {
		image.type = .D2
		image.format = createInfo.imageFormat
		image.extent = {
			width  = createInfo.imageExtent.width,
			height = createInfo.imageExtent.height,
		}
		image.usage = createInfo.imageUsage
		image.samples = {._1}
		name(device, swapchain.images.image[index], fmt.tprintf("%s's Swap %d", label, index))

		swapchain.views[index] = check(create_image_view(device, image, label = fmt.tprintf("%s's Swap %d", label, index))) or_return
		swapchain.semaphores[index] = create_binary_semaphore(device, fmt.tprintf("%s's Swap %d Present Finished Binary", label, index)) or_return
	}
	return
}

destroy_swapchain :: proc(device: Device, swapchain: Swapchain) {
	delete(swapchain.views)
	for &view in swapchain.views {
		v := view
		destroy_image_view(device, v)
		view = v
	}
	for &sempahore in swapchain.semaphores {
		s := sempahore
		destroy_semaphore(device, auto_cast s)
		sempahore = s
	}
	vk.DestroySwapchainKHR(device.device, swapchain.swapchain, nil)
}

swap_length :: proc(swapchain: Swapchain) -> int {
	return len(swapchain.images)
}

/* ----------------- */
/* ----- Fence ----- */
/* ----------------- */

create_fence :: proc(device: Device, signaled: bool = false, label := "") -> (fence: vk.Fence, result: vk.Result) {
	checkLabel(label)
	info: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
		flags = signaled ? {.SIGNALED} : {},
	}
	vk.CreateFence(device.device, &info, nil, &fence) or_return
	if len(label) > 0 {
		name(device, fence, label)
	}
	return
}

destroy_fence :: proc(device: Device, fence: vk.Fence) {
	vk.DestroyFence(device.device, fence, nil)
}

/* --------------------- */
/* ----- Semaphore ----- */
/* --------------------- */

Semaphore :: union {
	BinarySemaphore,
	TimelineSemaphore,
}

BinarySemaphore :: distinct vk.Semaphore
TimelineSemaphore :: distinct vk.Semaphore

create_binary_semaphore :: proc(device: Device, label := "") -> (semaphore: BinarySemaphore, result: vk.Result) {
	checkLabel(label)
	typeInfo: vk.SemaphoreTypeCreateInfo = {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		pNext         = nil,
		semaphoreType = .BINARY,
	}
	createInfo: vk.SemaphoreCreateInfo = {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &typeInfo,
		flags = {},
	}
	check(vk.CreateSemaphore(device.device, &createInfo, nil, auto_cast &semaphore)) or_return
	if len(label) > 0 {
		name(device, cast(vk.Semaphore)semaphore, label)
	}
	return
}

create_timeline_semaphore :: proc(device: Device, initialValue: u64 = 0, label := "") -> (semaphore: TimelineSemaphore, result: vk.Result) {
	checkLabel(label)
	typeInfo: vk.SemaphoreTypeCreateInfo = {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		pNext         = nil,
		semaphoreType = .TIMELINE,
		initialValue  = initialValue,
	}
	createInfo: vk.SemaphoreCreateInfo = {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &typeInfo,
		flags = {},
	}
	check(vk.CreateSemaphore(device.device, &createInfo, nil, auto_cast &semaphore)) or_return
	if len(label) > 0 {
		name(device, cast(vk.Semaphore)semaphore, label)
	}
	return
}

destroy_semaphore :: proc {
	destroy_binary_semaphore,
	destroy_timeline_semaphore,
}

destroy_binary_semaphore :: proc(device: Device, semaphore: BinarySemaphore) {
	vk.DestroySemaphore(device.device, auto_cast semaphore, nil)
}

destroy_timeline_semaphore :: proc(device: Device, semaphore: TimelineSemaphore) {
	vk.DestroySemaphore(device.device, auto_cast semaphore, nil)
}

/* --------------------- */
/* ----- Query Pool ----- */
/* --------------------- */

create_timestamp_query_pool :: proc(device: Device, queryCount: u32) -> (queryPool: vk.QueryPool, result: vk.Result) {
	createInfo: vk.QueryPoolCreateInfo = {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = queryCount,
	}
	vk.CreateQueryPool(device.device, &createInfo, nil, &queryPool) or_return
	return
}

destroy_query_pool :: proc(device: Device, queryPool: vk.QueryPool) {
	vk.DestroyQueryPool(device.device, queryPool, nil)
}

reset_query_pool :: proc(device: Device, queryPool: vk.QueryPool, queryCount: u32) -> vk.Result {
	vk.ResetQueryPool(device.device, queryPool, 0, queryCount)
	return .SUCCESS
}

get_timestamp_query_results :: proc(device: Device, queryPool: vk.QueryPool, queryCount: u32, results: []u64) -> vk.Result {
	assert(len(results) >= int(queryCount))
	return vk.GetQueryPoolResults(
		device.device,
		queryPool,
		0,
		queryCount,
		int(queryCount) * size_of(u64),
		raw_data(results),
		size_of(u64),
		{._64, .WAIT},
	)
}

/* ------------------ */
/* ----- Events ----- */
/* ------------------ */

Event :: struct {
	event:      vk.Event,
	deviceOnly: bool,
}

create_event :: proc(device: Device, deviceOnly: bool, label := "") -> (event: vk.Event, result: vk.Result) {
	checkLabel(label)
	eventCreateInfo: vk.EventCreateInfo = {
		sType = .EVENT_CREATE_INFO,
		flags = deviceOnly ? {.DEVICE_ONLY} : {},
	}

	check(vk.CreateEvent(device.device, &eventCreateInfo, nil, &event)) or_return
	if len(label) > 0 {
		name(device, event, label)
	}
	return
}

destroy_event :: proc(device: Device, event: Event) {
	vk.DestroyEvent(device.device, event.event, nil)
}

/* ------------------- */
/* ----- Command ----- */
/* ------------------- */

CommandPool :: struct {
	commandPool:         vk.CommandPool,
	commandBuffers:      [dynamic]vk.CommandBuffer,
	usedCommandBuffers:  [dynamic]vk.CommandBuffer,
	resetCommandBuffers: bool,
	queueFamilyIndex:    u32,
}

CommandBuffer :: struct {
	commandBuffer:    vk.CommandBuffer,
	queueFamilyIndex: u32,
	debugUtils:       bool,
}

create_command_pool :: proc(
	device: Device,
	queue: Queue,
	resetCommandBuffers := false,
	label := "",
	allocator := context.allocator,
) -> (
	commandPool: CommandPool,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = queue.familyIndex,
		flags            = resetCommandBuffers ? {.RESET_COMMAND_BUFFER} : {},
	}
	check(vk.CreateCommandPool(device.device, &createInfo, nil, &commandPool.commandPool)) or_return
	if len(label) > 0 {
		name(device, commandPool.commandPool, label)
	}
	commandPool.commandBuffers = make([dynamic]vk.CommandBuffer, allocator)
	commandPool.usedCommandBuffers = make([dynamic]vk.CommandBuffer, allocator)
	commandPool.resetCommandBuffers = .RESET_COMMAND_BUFFER in createInfo.flags
	commandPool.queueFamilyIndex = queue.familyIndex
	return
}

get_command_buffer :: proc(device: Device, commandPool: ^CommandPool, label := "") -> (commandBuffer: CommandBuffer, result: vk.Result) {
	checkLabel(label)
	cBuffer: vk.CommandBuffer
	make_command_buffers(device, commandPool, slice.from_ptr(&cBuffer, 1)) or_return
	commandBuffer = {
		commandBuffer    = cBuffer,
		queueFamilyIndex = commandPool.queueFamilyIndex,
		debugUtils       = .DebugUtils in device.instanceCapabilities,
	}
	if len(label) > 0 {
		name(device, cBuffer, label)
	}
	return
}

get_command_buffers :: proc(
	device: Device,
	commandPool: ^CommandPool,
	count: int,
	label := "",
	allocator := context.allocator,
) -> (
	commandBuffers: []CommandBuffer,
	result: vk.Result,
) {
	checkLabel(label)
	cBuffers := make([]vk.CommandBuffer, count, context.temp_allocator)
	make_command_buffers(device, commandPool, cBuffers) or_return
	commandBuffers = make([]CommandBuffer, count, allocator)
	for &commandBuffer, index in commandBuffers {
		commandBuffer = {
			commandBuffer    = cBuffers[index],
			queueFamilyIndex = commandPool.queueFamilyIndex,
			debugUtils       = .DebugUtils in device.instanceCapabilities,
		}
		if len(label) > 0 {
			name(device, cBuffers[index], fmt.tprintf("%s (%d)", label, index))
		}
	}
	return
}

@(private = "file")
make_command_buffers :: proc(device: Device, commandPool: ^CommandPool, commandBuffers: []vk.CommandBuffer) -> (result: vk.Result) {
	count := len(commandBuffers)
	available := len(commandPool.commandBuffers)
	extra := available - count
	if (count == 0) do return

	if available > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(commandBuffers), &commandPool.commandBuffers[extra], min(available, count) * size_of(vk.CommandBuffer))
		resize(&commandPool.commandBuffers, max(extra, 0))
	}

	needed := max(-extra, 0)
	if needed > 0 {
		check(allocate_command_buffers(device, commandPool.commandPool, commandBuffers[available:])) or_return
	}

	append_elems(&commandPool.usedCommandBuffers, ..commandBuffers)
	return
}

allocate_command_buffers :: proc(device: Device, commandPool: vk.CommandPool, commandBuffers: []vk.CommandBuffer) -> (result: vk.Result) {
	allocInfo: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = commandPool,
		commandBufferCount = u32(len(commandBuffers)),
		level              = .PRIMARY,
	}
	check(vk.AllocateCommandBuffers(device.device, &allocInfo, raw_data(commandBuffers))) or_return
	return
}

reset_command_pool :: proc(device: Device, commandPool: ^CommandPool) -> (result: vk.Result) {
	check(vk.ResetCommandPool(device.device, commandPool.commandPool, {})) or_return
	append(&commandPool.commandBuffers, ..commandPool.usedCommandBuffers[:])
	clear(&commandPool.usedCommandBuffers)
	return
}

reset_command_buffer :: proc(device: Device, commandPool: ^CommandPool, commandBuffer: CommandBuffer) {
	check(commandPool.resetCommandBuffers)
	index := assert(slice.linear_search(commandPool.usedCommandBuffers[:], commandBuffer.commandBuffer))
	check(vk.ResetCommandBuffer(commandBuffer.commandBuffer, {}))
	unordered_remove(&commandPool.usedCommandBuffers, index)
	append(&commandPool.commandBuffers, commandBuffer.commandBuffer)
	return
}

destroy_command_pool :: proc(device: Device, commandPool: CommandPool) {
	vk.DestroyCommandPool(device.device, commandPool.commandPool, nil)
	delete(commandPool.commandBuffers)
	delete(commandPool.usedCommandBuffers)
}

/* ----------------------- */
/* ----- Descriptors ----- */
/* ----------------------- */

DescriptorSetLayout :: struct {
	layout:   vk.DescriptorSetLayout,
	bindings: []vk.DescriptorSetLayoutBinding,
}

create_descriptor_set_layout :: proc(
	device: Device,
	bindings: []vk.DescriptorSetLayoutBinding,
	label := "",
	allocator := context.allocator,
) -> (
	layout: DescriptorSetLayout,
	result: vk.Result,
) {
	checkLabel(label)
	bindingFlags := make([]vk.DescriptorBindingFlags, len(bindings), context.temp_allocator)
	bindingInfo: vk.DescriptorSetLayoutBindingFlagsCreateInfo = {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(bindings)),
		pBindingFlags = raw_data(bindingFlags),
	}
	for &binding in bindingFlags {
		binding = .DescriptorIndexing in device.enabledCapabilities ? {.UPDATE_AFTER_BIND, .PARTIALLY_BOUND, .UPDATE_UNUSED_WHILE_PENDING} : {}
	}
	createInfo: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		flags        = .DescriptorIndexing in device.enabledCapabilities ? {.UPDATE_AFTER_BIND_POOL} : {},
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
		pNext        = &bindingInfo,
	}
	vk.CreateDescriptorSetLayout(device.device, &createInfo, nil, &layout.layout) or_return
	if len(label) > 0 {
		name(device, layout.layout, label)
	}
	layout.bindings = slice.clone(bindings, allocator)
	return
}

destroy_descriptor_set_layout :: proc(device: Device, layout: DescriptorSetLayout) {
	vk.DestroyDescriptorSetLayout(device.device, layout.layout, nil)
	delete(layout.bindings)
	return
}

DescriptorPool :: struct {
	pool:         vk.DescriptorPool,
	setCapacity:  u32,
	setAvailable: u32,
	capacity:     map[vk.DescriptorType]u32,
	available:    map[vk.DescriptorType]u32,
}

create_descriptor_pool :: proc(
	device: Device,
	#any_int maxSets: u32,
	layout: DescriptorSetLayout,
	label := "",
	allocator := context.allocator,
) -> (
	pool: DescriptorPool,
	result: vk.Result,
) {
	checkLabel(label)
	sizes := make(map[vk.DescriptorType]u32, context.temp_allocator)
	for binding in layout.bindings {
		if binding.descriptorType in sizes do sizes[binding.descriptorType] += binding.descriptorCount
		else do sizes[binding.descriptorType] = binding.descriptorCount
	}
	poolSizes := make([]vk.DescriptorPoolSize, len(sizes), context.temp_allocator)
	sizeIndex := 0
	for key, value in sizes {
		poolSizes[sizeIndex] = {
			type            = key,
			descriptorCount = value * maxSets,
		}
		sizeIndex += 1
	}
	createInfo: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = maxSets,
		poolSizeCount = u32(len(poolSizes)),
		pPoolSizes    = raw_data(poolSizes),
	}
	vk.CreateDescriptorPool(device.device, &createInfo, nil, &pool.pool) or_return
	if len(label) > 0 {
		name(device, pool.pool, label)
	}

	pool.capacity = make(map[vk.DescriptorType]u32, allocator)
	pool.available = make(map[vk.DescriptorType]u32, allocator)
	pool.setCapacity = maxSets
	pool.setAvailable = maxSets

	return
}

destroy_descriptor_pool :: proc(device: Device, pool: DescriptorPool) -> (result: vk.Result) {
	vk.DestroyDescriptorPool(device.device, pool.pool, nil)
	delete(pool.capacity)
	delete(pool.available)
	return
}

reset_descriptor_pool :: proc(device: Device, pool: ^DescriptorPool) -> (result: vk.Result) {
	vk.ResetDescriptorPool(device.device, pool.pool, {}) or_return
	for key, &value in pool.available {
		value = pool.capacity[key]
	}
	pool.setAvailable = pool.setCapacity
	return
}

allocate_descriptor_set :: proc(
	device: Device,
	pool: DescriptorPool,
	layout: DescriptorSetLayout,
	label := "",
) -> (
	descriptorSet: vk.DescriptorSet,
	result: vk.Result,
) {
	checkLabel(label)
	setLayout := layout.layout
	allocInfo: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = pool.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &setLayout,
	}
	vk.AllocateDescriptorSets(device.device, &allocInfo, &descriptorSet) or_return
	if len(label) > 0 {
		name(device, descriptorSet, label)
	}
	return
}

update_descriptor_sets :: proc(device: Device, writes: []vk.WriteDescriptorSet = {}, copies: []vk.CopyDescriptorSet = {}) {
	for &write in writes do write.sType = .WRITE_DESCRIPTOR_SET
	for &copy in copies do copy.sType = .COPY_DESCRIPTOR_SET
	vk.UpdateDescriptorSets(device.device, u32(len(writes)), raw_data(writes), u32(len(copies)), raw_data(copies))
}

/* ------------------- */
/* ----- Shaders ----- */
/* ------------------- */

@(rodata)
SHADER_KIND_STAGES: [ShaderKind][]vk.ShaderStageFlag = {
	.Dispatch = {.COMPUTE},
	.Raster   = {.VERTEX, .FRAGMENT},
	.Mesh     = {.TASK_EXT, .MESH_EXT, .FRAGMENT},
}

ShaderKind :: enum {
	Dispatch,
	Raster,
	Mesh,
}

ShaderKinds :: bit_set[ShaderKind]

ShaderEntryPoint :: struct {
	name:  string,
	stage: vk.ShaderStageFlag,
}

ShaderInfo :: struct {
	code:               []byte,
	entryPoints:        []ShaderEntryPoint,
	specializationInfo: []vk.SpecializationInfo,
}

create_specialization_info :: proc(
	specializationConstants: $T,
	allocator := context.temp_allocator,
	loc := #caller_location,
) -> vk.SpecializationInfo where intrinsics.type_is_struct(T) {
	specializationMap := make([dynamic]vk.SpecializationMapEntry, allocator, loc)
	append_specialization_entries(&specializationMap, type_info_of(T), 0)
	specConstants := new(T, allocator, loc)
	specConstants^ = specializationConstants

	return {
		mapEntryCount = u32(len(specializationMap)),
		pMapEntries = raw_data(specializationMap),
		dataSize = size_of(specializationConstants),
		pData = specConstants,
	}
}

append_specialization_entries :: proc(entries: ^[dynamic]vk.SpecializationMapEntry, typeInfo: ^reflect.Type_Info, baseOffset: uintptr) {
	typeInfoBase := runtime.type_info_base(typeInfo)
	#partial switch structInfo in typeInfoBase.variant {
	case runtime.Type_Info_Struct:
		for index in 0 ..< int(structInfo.field_count) {
			fieldType := structInfo.types[index]
			fieldOffset := baseOffset + structInfo.offsets[index]
			fieldTypeBase := runtime.type_info_base(fieldType)
			#partial switch fieldStructInfo in fieldTypeBase.variant {
			case runtime.Type_Info_Struct:
				if structInfo.usings[index] {
					append_specialization_entries(entries, fieldType, fieldOffset)
					continue
				}
			}
			assert(is_vulkan_specialization_constant_type(fieldTypeBase))
			append(entries, vk.SpecializationMapEntry{constantID = u32(len(entries^)), offset = u32(fieldOffset), size = fieldTypeBase.size})
		}
	}
}

is_vulkan_specialization_constant_type :: proc(typeInfo: ^reflect.Type_Info) -> bool {
	_, isInteger := typeInfo.variant.(runtime.Type_Info_Integer)
	_, isFloat := typeInfo.variant.(runtime.Type_Info_Float)
	_, isBoolean := typeInfo.variant.(runtime.Type_Info_Boolean)
	return isInteger || isFloat || isBoolean
}

free_specialization_info :: proc(info: vk.SpecializationInfo, allocator := context.allocator) {
	free(info.pMapEntries, allocator)
	free(info.pData, allocator)
}

@(require_results)
create_shaders :: proc(
	device: Device,
	info: ShaderInfo,
	setLayouts: []vk.DescriptorSetLayout = {},
	pushConstantRanges: []vk.PushConstantRange = {},
	link := true,
	label := "",
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	shaders: []vk.ShaderEXT,
	stages: []vk.ShaderStageFlags,
	result: vk.Result,
) {
	checkLabel(label)
	if len(info.code) == 0 do return

	shaderCount := len(info.entryPoints)
	if shaderCount == 0 do return

	// Ensure code begin and end are aligned to 4 bytes
	code := info.code
	if (uintptr(&code[0]) & (4 - 1) != 0) || (len(code) % 4 != 0) {
		c, _ := runtime.make_aligned([]byte, 4 * ((len(code) + 3) / 4), 4, context.temp_allocator)
		copy_slice(c, code)
		code = c
	}

	shaderCreateInfos, _ := make([]vk.ShaderCreateInfoEXT, shaderCount, context.temp_allocator)
	shaders, _ = make([]vk.ShaderEXT, shaderCount, allocator, loc)
	stages, _ = make([]vk.ShaderStageFlags, shaderCount, allocator, loc)

	for entryPoint, index in info.entryPoints {
		stages[index] = {entryPoint.stage}
	}

	for entryPoint, index in info.entryPoints {
		name := strings.clone_to_cstring(entryPoint.name, context.temp_allocator)
		shaderCreateInfos[index] = {
			sType                  = .SHADER_CREATE_INFO_EXT,
			flags                  = link && len(info.entryPoints) > 1 ? {.LINK_STAGE} : {},
			stage                  = stages[index],
			nextStage              = {},
			codeType               = .SPIRV,
			codeSize               = len(code),
			pCode                  = raw_data(code),
			pName                  = name,
			setLayoutCount         = u32(len(setLayouts)),
			pSetLayouts            = raw_data(setLayouts),
			pushConstantRangeCount = u32(len(pushConstantRanges)),
			pPushConstantRanges    = raw_data(pushConstantRanges),
			pSpecializationInfo    = len(info.specializationInfo) == 0 ? nil : len(info.specializationInfo) == 1 ? &info.specializationInfo[0] : &info.specializationInfo[index],
		}
		if entryPoint.stage == .MESH_EXT && slice.contains(stages, vk.ShaderStageFlags{.TASK_EXT}) {
			shaderCreateInfos[index].flags |= {.NO_TASK_SHADER}
		}

		nextStages: []vk.ShaderStageFlag
		#partial switch entryPoint.stage {
		case .VERTEX:
			nextStages = {.GEOMETRY, .TESSELLATION_CONTROL, .FRAGMENT}
		case .TESSELLATION_CONTROL:
			nextStages = {.TESSELLATION_EVALUATION}
		case .TESSELLATION_EVALUATION:
			nextStages = {.GEOMETRY, .FRAGMENT}
		case .GEOMETRY:
			nextStages = {.FRAGMENT}
		case .TASK_EXT:
			nextStages = {.MESH_EXT}
		case .MESH_EXT:
			nextStages = {.FRAGMENT}
		}
		for nextStage in nextStages {
			if slice.contains(stages, vk.ShaderStageFlags{nextStage}) {
				shaderCreateInfos[index].nextStage = {nextStage}
				break
			}
		}
	}

	check(vk.CreateShadersEXT(device.device, u32(shaderCount), raw_data(shaderCreateInfos), nil, raw_data(shaders))) or_return
	if len(label) > 0 {
		for s, i in shaders {
			shaderLabel := len(shaders) > 1 ? fmt.tprintf("%s (%v)", label, stages[i]) : label
			name(device, s, shaderLabel)
		}
	}
	return
}

destroy_shader :: proc(device: Device, shader: vk.ShaderEXT) {
	vk.DestroyShaderEXT(device.device, shader, nil)
}

GraphicsTechnique :: struct {
	using rasterizationOptions: RasterizationOptions,
	using blendOptions:         BlendOptions,
	multisample:                vk.SampleCountFlags,
	shaderInfo:                 ShaderInfo,
	dynamicsState:              map[vk.DynamicState]struct{},
}

RasterizationOptions :: struct {
	topology:    vk.PrimitiveTopology,
	polygonMode: vk.PolygonMode,
	cullMode:    vk.CullModeFlags,
	frontFace:   vk.FrontFace,
	lineWidth:   f32,
}

BlendOptions :: struct {
	logicOperation: Maybe(vk.LogicOp),
	writeMask:      vk.ColorComponentFlags,
	colorOperation: Maybe(BlendOperation),
	alphaOperation: Maybe(BlendOperation),
}

BlendOperation :: struct {
	sourceFactor:      vk.BlendFactor,
	destinationFactor: vk.BlendFactor,
	operation:         vk.BlendOp,
}

create_pipeline_layout :: proc(
	device: Device,
	descriptorSetLayouts: []vk.DescriptorSetLayout = {},
	pushConstantRanges: []vk.PushConstantRange = {},
	label := "",
) -> (
	layout: vk.PipelineLayout,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.PipelineLayoutCreateInfo = {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		flags                  = {},
		setLayoutCount         = u32(len(descriptorSetLayouts)),
		pSetLayouts            = raw_data(descriptorSetLayouts),
		pushConstantRangeCount = u32(len(pushConstantRanges)),
		pPushConstantRanges    = raw_data(pushConstantRanges),
	}

	check(vk.CreatePipelineLayout(device.device, &createInfo, nil, &layout)) or_return
	if len(label) > 0 {
		name(device, layout, label)
	}
	return
}

destroy_pipeline_layout :: proc(device: Device, layout: vk.PipelineLayout) {
	vk.DestroyPipelineLayout(device.device, layout, nil)
}

/* ------------------ */
/* ----- Memory ----- */
/* ------------------ */

Memory :: struct {
	memory:     vk.DeviceMemory,
	type:       u32,
	properties: vk.MemoryPropertyFlags,
	size:       vk.DeviceSize,
	mappedData: rawptr,
}

allocate_memory :: proc(device: Device, memoryType: u32, size: vk.DeviceSize, label := "") -> (memory: Memory, result: vk.Result) {
	checkLabel(label)
	flags_info: vk.MemoryAllocateFlagsInfo
	alloc_info: vk.MemoryAllocateInfo = {
		sType           = .MEMORY_ALLOCATE_INFO,
		memoryTypeIndex = memoryType,
		allocationSize  = size,
	}
	if .BufferDeviceAddress in device.enabledCapabilities {
		flags_info = {
			sType = .MEMORY_ALLOCATE_FLAGS_INFO,
			flags = {.DEVICE_ADDRESS},
		}
		alloc_info.pNext = &flags_info
	}
	check(vk.AllocateMemory(device.device, &alloc_info, nil, &memory.memory)) or_return
	memory.type = memoryType
	memory.properties = get_memory_properties(device.physicalDevice, memoryType)
	memory.size = size
	if .HOST_VISIBLE in memory.properties {
		check(vk.MapMemory(device.device, memory.memory, 0, memory.size, {}, &memory.mappedData)) or_return
	}
	if len(label) > 0 {
		name(device, memory.memory, label)
	}
	return
}

free_memory :: proc(device: Device, memory: Memory) {
	vk.FreeMemory(device.device, memory.memory, nil)
}

/* --------------------- */
/* ----- Resources ----- */
/* --------------------- */

GpuResource :: struct {
	memory:      Memory,
	offset:      vk.DeviceSize,
	size:        vk.DeviceSize,
	sharingMode: vk.SharingMode,
}

@(require_results)
bind :: proc {
	bind_buffer_to_memory,
	bind_buffer_to_dedicated_memory,
	bind_buffer_to_dynamic_gpu_arena,
	bind_image_to_memory,
	bind_image_to_dedicated_memory,
	bind_image_to_dynamic_gpu_arena,
}

/* ------------------ */
/* ----- Buffer ----- */
/* ------------------ */

Buffer :: struct {
	buffer:            vk.Buffer,
	usage:             vk.BufferUsageFlags,
	using gpuResource: GpuResource,
}

BufferView :: struct {
	view: vk.BufferView,
}

@(require_results)
create_buffer :: proc(
	device: Device,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	sharingMode: vk.SharingMode = .EXCLUSIVE,
	queueFamilyIndices: []u32 = {},
	label := "",
) -> (
	buffer: Buffer,
	result: vk.Result,
) {
	checkLabel(label)
	bufferInfo: vk.BufferCreateInfo = {
		sType                 = .BUFFER_CREATE_INFO,
		size                  = size,
		usage                 = usage,
		sharingMode           = sharingMode,
		queueFamilyIndexCount = auto_cast len(queueFamilyIndices),
		pQueueFamilyIndices   = raw_data(queueFamilyIndices),
	}
	if .BufferDeviceAddress in device.enabledCapabilities do bufferInfo.usage |= {.SHADER_DEVICE_ADDRESS}
	vk.CreateBuffer(device.device, &bufferInfo, nil, &buffer.buffer) or_return
	buffer.size, buffer.usage, buffer.sharingMode = size, usage, sharingMode
	if len(label) > 0 {
		name(device, buffer.buffer, label)
	}
	return
}

destroy_buffer :: proc(device: Device, buffer: Buffer) {
	vk.DestroyBuffer(device.device, buffer.buffer, nil)
}

release_buffer :: proc(device: Device, buffer: Buffer) {
	destroy_buffer(device, buffer)
	free_memory(device, buffer.memory)
}

@(require_results)
bind_buffer :: proc {
	bind_buffer_to_memory,
	bind_buffer_to_dedicated_memory,
	bind_buffer_to_dynamic_gpu_arena,
}

@(require_results)
bind_buffer_to_memory :: proc(device: Device, buffer: ^Buffer, memory: Memory, offset: vk.DeviceSize) -> (result: vk.Result) {
	check(vk.BindBufferMemory(device.device, buffer.buffer, memory.memory, offset)) or_return
	buffer.memory = memory
	buffer.offset = offset
	return
}

@(require_results)
bind_buffer_to_dedicated_memory :: proc(device: Device, buffer: ^Buffer, memoryType: u32, label := "") -> (result: vk.Result) {
	checkLabel(label)
	memoryRequirements := get_memory_requirements(device, buffer^)
	assert(bits.bitfield_extract(memoryRequirements.memoryTypeBits, auto_cast memoryType, 1) == 1)
	memory := check(allocate_memory(device, memoryType, memoryRequirements.size)) or_return
	check(bind(device, buffer, memory, 0)) or_return
	return
}

@(require_results)
bind_buffer_to_dynamic_gpu_arena :: proc(arena: ^DynamicGpuArena, buffer: ^Buffer) -> (result: vk.Result) {
	memoryRequirements := get_memory_requirements(arena.device, buffer^)
	memory, offset := check(dynamic_gpu_arena_allocate_by_requirements(arena, memoryRequirements)) or_return
	check(bind(arena.device, buffer, memory, offset)) or_return
	return
}

@(require_results)
create_buffer_view :: proc(
	device: Device,
	buffer: Buffer,
	format := vk.Format.UNDEFINED,
	offset: Maybe(vk.DeviceSize) = {},
	range: Maybe(vk.DeviceSize) = {},
	label := "",
) -> (
	view: BufferView,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.BufferViewCreateInfo = {
		sType  = .BUFFER_VIEW_CREATE_INFO,
		flags  = {},
		buffer = buffer.buffer,
		format = format,
		offset = offset.(vk.DeviceSize) or_else 0,
		range  = range.(vk.DeviceSize) or_else buffer.size,
	}
	vk.CreateBufferView(device.device, &createInfo, nil, &view.view) or_return
	if len(label) > 0 {
		name(device, view.view, label)
	}
	return
}

destroy_buffer_view :: proc(device: Device, view: BufferView) {
	vk.DestroyBufferView(device.device, view.view, nil)
}

/* ----------------- */
/* ----- Image ----- */
/* ----------------- */

create_sampler :: proc(
	device: Device,
	magFilter, minFilter: vk.Filter,
	mipMapMode: vk.SamplerMipmapMode,
	addressMode: [3]vk.SamplerAddressMode,
	unnormalizedCoordinates: b32,
	label := "",
) -> (
	sampler: vk.Sampler,
	result: vk.Result,
) {
	checkLabel(label)
	samplerCreateInfo: vk.SamplerCreateInfo = {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = magFilter,
		minFilter               = minFilter,
		mipmapMode              = mipMapMode,
		addressModeU            = addressMode.x,
		addressModeV            = addressMode.y,
		addressModeW            = addressMode.z,
		unnormalizedCoordinates = unnormalizedCoordinates,
	}
	check(vk.CreateSampler(device.device, &samplerCreateInfo, nil, &sampler)) or_return
	if len(label) > 0 {
		name(device, sampler, label)
	}
	return
}

Image :: struct {
	image:             vk.Image,
	type:              vk.ImageType,
	format:            vk.Format,
	extent:            vk.Extent3D,
	usage:             vk.ImageUsageFlags,
	mipLevels:         u32,
	arrayLayers:       u32,
	samples:           vk.SampleCountFlags,
	tiling:            vk.ImageTiling,
	using gpuResource: GpuResource,
	stagingImage:      ^Image,
}

ImageView :: struct {
	view: vk.ImageView,
}

@(require_results)
create_image :: proc(
	device: Device,
	format: vk.Format,
	extent: vk.Extent3D,
	usage: vk.ImageUsageFlags = {},
	imageType: vk.ImageType = .D2,
	sharingMode: vk.SharingMode = .EXCLUSIVE,
	arrayLayers := u32(1),
	mipLevels := u32(1),
	samples: vk.SampleCountFlags = {._1},
	tiling := vk.ImageTiling.OPTIMAL,
	initialLayout: vk.ImageLayout = .UNDEFINED,
	queueFamilyIndices: []u32 = {},
	label := "",
) -> (
	image: Image,
	result: vk.Result,
) {
	checkLabel(label)
	imageInfo: vk.ImageCreateInfo = {
		sType                 = .IMAGE_CREATE_INFO,
		format                = format,
		extent                = extent,
		usage                 = usage,
		imageType             = imageType,
		sharingMode           = sharingMode,
		arrayLayers           = arrayLayers,
		mipLevels             = mipLevels,
		samples               = samples,
		tiling                = tiling,
		initialLayout         = initialLayout,
		queueFamilyIndexCount = auto_cast len(queueFamilyIndices),
		pQueueFamilyIndices   = raw_data(queueFamilyIndices),
	}
	check(vk.CreateImage(device.device, &imageInfo, nil, &image.image)) or_return
	image.format, image.extent, image.size, image.usage, image.type, image.sharingMode, image.arrayLayers, image.mipLevels, image.samples, image.tiling =
		format,
		extent,
		vk.DeviceSize(extent.width * extent.height * extent.depth * get_bytes_per_pixel(format)),
		usage,
		imageType,
		sharingMode,
		arrayLayers,
		mipLevels,
		samples,
		tiling
	if len(label) > 0 {
		name(device, image.image, label)
	}
	return
}

destroy_image :: proc(device: Device, image: Image) {
	vk.DestroyImage(device.device, image.image, nil)
}

@(require_results)
bind_image :: proc {
	bind_image_to_memory,
	bind_image_to_dedicated_memory,
	bind_image_to_dynamic_gpu_arena,
}

@(require_results)
bind_image_to_memory :: proc(device: Device, image: ^Image, memory: Memory, offset: vk.DeviceSize) -> (result: vk.Result) {
	check(vk.BindImageMemory(device.device, image.image, memory.memory, offset)) or_return
	image.memory = memory
	image.offset = offset
	return
}

@(require_results)
bind_image_to_dedicated_memory :: proc(device: Device, image: ^Image, memoryType: u32, label := "") -> (result: vk.Result) {
	checkLabel(label)
	memoryRequirements := get_memory_requirements(device, image^)
	assert(bits.bitfield_extract(memoryRequirements.memoryTypeBits, auto_cast memoryType, 1) == 1)
	memory := check(allocate_memory(device, memoryType, memoryRequirements.size, label)) or_return
	bind(device, image, memory, 0) or_return
	return
}

@(require_results)
bind_image_to_dynamic_gpu_arena :: proc(arena: ^DynamicGpuArena, image: ^Image) -> (result: vk.Result) {
	memoryRequirements := get_memory_requirements(arena.device, image^)
	memory, offset := check(dynamic_gpu_arena_allocate_by_requirements(arena, memoryRequirements)) or_return
	bind(arena.device, image, memory, offset) or_return
	return
}

@(require_results)
create_image_view :: proc(
	device: Device,
	image: Image,
	format := vk.Format.UNDEFINED,
	aspectMask: vk.ImageAspectFlags = {.COLOR},
	components: vk.ComponentMapping = {},
	layer: u32 = 0,
	label := "",
) -> (
	view: ImageView,
	result: vk.Result,
) {
	checkLabel(label)
	createInfo: vk.ImageViewCreateInfo = {
		sType = .IMAGE_VIEW_CREATE_INFO,
		flags = {},
		image = image.image,
		viewType = image.type == .D1 ? .D1 : (image.type == .D2 ? .D2 : .D3),
		format = (format != .UNDEFINED) ? format : image.format,
		components = components,
		subresourceRange = {aspectMask = aspectMask, baseArrayLayer = layer, layerCount = 1, baseMipLevel = 0, levelCount = vk.REMAINING_MIP_LEVELS},
	}
	vk.CreateImageView(device.device, &createInfo, nil, &view.view) or_return
	if len(label) > 0 {
		name(device, view.view, label)
	}
	return
}

destroy_image_view :: proc(device: Device, view: ImageView) {
	vk.DestroyImageView(device.device, view.view, nil)
}

@(private = "package")
checkLabel :: #force_inline proc(label: string, loc := #caller_location) {
	when REQUIRE_RESOURCE_LABELS {
		if !EXCUSE_RESOURCE_LABELS {
			assert(len(label) > 0, "Resource label required when REQUIRE_RESOURCE_LABELS is enabled", loc)
		}
	}
}
