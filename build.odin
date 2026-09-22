package ekhos_build

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import si "core:sys/info"
import util "src/utility"

when ODIN_DEBUG { EKHOS_DEFAULT_BUILD_MODE :: "debug" } else { EKHOS_DEFAULT_BUILD_MODE :: "release" }
EKHOS_BUILD_MODE: string
EKHOS_DEFAULT_BUILD_TYPE :: "lib"
EKHOS_BUILD_TYPE: string

INSTALL_LOCATION :: #config(INSTALL_LOCATION, ".")

TMP_DIRECTORY :: #config(TMP_DIRECTORY, "tmp/")
EXTERN_DIRECTORY :: #config(EXTERN_DIRECTORY, "extern/")
IMPORT_DIRECTORY :: #config(IMPORT_DIRECTORY, "import/")

EKHOS_BINARY_OUT_DIR := "bin"
EKHOS_LIBRARY_OUT_DIR := "lib"
EKHOS_RELEASE_OUT_SUBDIR := "release"
EKHOS_DEBUG_OUT_SUBDIR := "debug"
EKHOS_OUTPUT_SUBDIR := ""
EKHOS_OUTPUT_LIB_NAME := "Ekhos"
EKHOS_TESTS_NAME := "ekhosTests"
EKHOS_MATLAB := #config(MATLAB, true)
EKHOS_ADDRESS_SANITIZER := #config(ADDRESS_SANITIZER, true)

LOG_DEBUG := #config(LOG_DEBUG, false)

EKHOS_SRC_DIR := "src"
MATLAB_DIR := "matlab"
EKHOS_TEST_DIR := "test"
EKHOS_TEST_EXE_TYPE := #config(TEST_EXE_TYPE, "test") // "test" or "exe"

EKHOS_COLLECTIONS: []OdinCollection = {{name = "ekhos", path = "src"}, {name = "import", path = IMPORT_DIRECTORY}}
EKHOS_ODIN_BUILD_OPTIONS: []OdinBuildOption = {}
EKHOS_ODIN_RELEASE_OPTIONS: []OdinBuildOption = {{flag = "o", value = {"speed"}}}
EKHOS_ODIN_DEBUG_OPTIONS: []OdinBuildOption = {{flag = "debug"}}
EKHOS_ODIN_TEST_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {EKHOS_TEST_EXE_TYPE}}}
EKHOS_ODIN_LIB_OPTIONS: []OdinBuildOption = {{flag = "build-mode", value = {"lib"}}, {flag = "reloc-mode", value = {"pic"}}}

EKHOS_ODIN_TEST_DEFINES: []OdinDefine = {{name = "ODIN_TEST_THREADS", value = "1"}, {name = "ODIN_TEST_RANDOM_SEED", value = "0xcafebabe"}}
EKHOS_ODIN_PROFILE_DEFINES: []OdinDefine = {{name = "PROF_MODE", value = "1"}, {name = "ENABLE_RENDERDOC", value = "false"}}
EKHOS_ODIN_BENCHMARK_DEFINES: []OdinDefine = {{name = "BENCHMARK", value = "true"}}

EKHOS_ODIN_DEBUG_DEFINES: []OdinDefine = {{name = "REQUIRE_RESOURCE_LABELS", value = "false"}}

@(private = "file")
is_ok :: util.is_ok
@(private = "file")
confirm :: util.confirm
@(private = "file")
check :: util.check
@(private = "file")
assert :: util.assert
@(private = "file")
assume :: util.assume

EKHOS_GLSLANG_OPTIONS: []CliOptions = {{flag = 'V'}, {flag = 'e', value = "main"}, {flag = "target-env", value = "vulkan1.2"}, {flag = "spirv-val"}}

main :: proc() {
	logger: runtime.Logger
	if LOG_DEBUG do logger = log.create_console_logger(.Debug)
	else do logger = log.create_console_logger(.Info)
	logger.options -= {.Level, .Date, .Time, .Line, .Procedure, .Short_File_Path}
	log.create_console_logger()
	context.logger = logger

	options := make([dynamic]OdinBuildOption)
	append(&options, ..EKHOS_ODIN_BUILD_OPTIONS)
	append(&options, ..odin_collections_to_options(EKHOS_COLLECTIONS))

	cpuStageTiming := false
	gpuStageTiming := false
	planStageTiming := false
	args := os.args
	for arg in args {
		switch arg {
		case "-d":
			fallthrough
		case "-debug":
			EKHOS_BUILD_MODE = "debug"
		case "-r":
			fallthrough
		case "-release":
			EKHOS_BUILD_MODE = "release"
		case "-l":
			fallthrough
		case "-lib":
			EKHOS_BUILD_TYPE = "lib"
		case "-t":
			fallthrough
		case "-tests":
			fallthrough
		case "-test":
			EKHOS_BUILD_TYPE = "test"
		case "-matlab":
			EKHOS_MATLAB = true
		case "-profile":
			append(&options, ..odin_defines_to_options(EKHOS_ODIN_PROFILE_DEFINES))
		case "-benchmark":
			EKHOS_BUILD_TYPE = "test"
			append(&options, ..odin_defines_to_options(EKHOS_ODIN_BENCHMARK_DEFINES))
		case "-gpu-stage-timing":
			gpuStageTiming = true
		case "-cpu-stage-timing":
			cpuStageTiming = true
		case "-plan-stage-timing":
			planStageTiming = true
		case "-all-stage-timing":
			cpuStageTiming = true
			gpuStageTiming = true
			planStageTiming = true
		case "-asan":
			EKHOS_ADDRESS_SANITIZER = true
		case "-no-break":
			append(&options, ..odin_defines_to_options({{"MESSENGER_BREAKPOINT", "false"}}))
		}
	}
	if cpuStageTiming do append(&options, OdinBuildOption{flag = "define", value = {"CPU_STAGE_TIMING=true"}})
	if gpuStageTiming do append(&options, OdinBuildOption{flag = "define", value = {"GPU_STAGE_TIMING=true"}})
	if planStageTiming do append(&options, OdinBuildOption{flag = "define", value = {"PLAN_STAGE_TIMING=true"}})
	if cpuStageTiming || gpuStageTiming || planStageTiming {
		append(&options, OdinBuildOption{flag = "define", value = {"ODIN_TEST_FANCY=false"}})
	}

	features := si.cpu_features()
	append(&options, OdinBuildOption{flag = "microarch", value = {"native"}})
	if .avx512f in features && .avx512bw in features && .avx512dq in features {
		append(&options, OdinBuildOption{flag = "target-features", value = {"avx512f,avx512bw,avx512dq"}})
	} else if .avx2 in features {
		append(&options, OdinBuildOption{flag = "target-features", value = {"avx2"}})
	}

	if len(EKHOS_BUILD_MODE) == 0 {
		EKHOS_BUILD_MODE = EKHOS_DEFAULT_BUILD_MODE
	}
	if len(EKHOS_BUILD_TYPE) == 0 {
		EKHOS_BUILD_TYPE = EKHOS_DEFAULT_BUILD_TYPE
	}
	if len(EKHOS_OUTPUT_SUBDIR) == 0 {
		switch EKHOS_BUILD_MODE {
		case "release":
			EKHOS_OUTPUT_SUBDIR = EKHOS_RELEASE_OUT_SUBDIR
		case "debug":
			EKHOS_OUTPUT_SUBDIR = EKHOS_DEBUG_OUT_SUBDIR
		}
	}
	switch EKHOS_BUILD_MODE {
	case "release":
		append(&options, ..EKHOS_ODIN_RELEASE_OPTIONS)
	case "debug":
		append(&options, ..EKHOS_ODIN_DEBUG_OPTIONS)
		if EKHOS_ADDRESS_SANITIZER {
			append(&options, OdinBuildOption{flag = "sanitize", value = {"address"}})
		}
		append(&options, ..odin_defines_to_options(EKHOS_ODIN_DEBUG_DEFINES))
	}
	switch EKHOS_BUILD_TYPE {
	case "lib":
		build_lib(&options)
	case "test":
		build_test(&options)
	}
}

build_lib :: proc(options: ^[dynamic]OdinBuildOption) -> (ok := true) {
	assert(check_cmd(ODIN_CMD), fmt.aprintf("Odin Command \"%v\" not found", ODIN_CMD))
	assert(check_cmd(SLANG_CMD), fmt.aprintf("Slang Command \"%v\" not found", SLANG_CMD))

	// Compile Shaders
	for shader in EKHOS_PULSE_ECHO_SHADERS do confirm(compile_shader_slangc(shader))

	// Compile PFFFT
	build_pffft() or_return

	outputDir := assume(os.join_path({INSTALL_LOCATION, EKHOS_LIBRARY_OUT_DIR, EKHOS_OUTPUT_SUBDIR}, context.allocator))
	// Make Output Directory
	if !os.is_directory(outputDir) {
		build_log(os.stdout, .Info, fmt.tprintf("Making Directory %s", outputDir))
		os.make_directory_all(outputDir)
	}

	// Odin Compilation
	when ODIN_OS == .Windows {
		libraryName := assume(os.join_filename(EKHOS_OUTPUT_LIB_NAME, "lib", context.allocator))
		_, cppCompilerKind, _ := detect_cpp_compiler()
		if cppCompilerKind == .MSVC do append(options, OdinBuildOption{flag = "extra-linker-flags", value = {"/IGNORE:4006"}})
	} else when ODIN_OS == .Linux {
		libraryName := assume(os.join_filename(EKHOS_OUTPUT_LIB_NAME, "a", context.allocator))
	}
	libraryOutPath := assume(os.join_path({outputDir, libraryName}, context.allocator))
	append(options, ..EKHOS_ODIN_LIB_OPTIONS)
	append(options, OdinBuildOption{flag = "out", value = {libraryOutPath}})

	odinCmd := make([dynamic]string)
	append(&odinCmd, ODIN_CMD, ODIN_BUILD_ARG, EKHOS_SRC_DIR)
	append(&odinCmd, ..odin_options_to_args(options[:]))
	assert(assert(run_cmd(odinCmd[:])) == 0)
	pffftObjectPath := assume(os.join_path({TMP_DIRECTORY + "pffft/", assume(os.join_filename("pffft", get_cpp_object_extension(CPP_COMPILER_KIND), context.temp_allocator))}, context.allocator))
	append_object_to_static_library(CPP_COMPILER_KIND, libraryOutPath, pffftObjectPath) or_return

	if EKHOS_MATLAB {
		when ODIN_OS == .Windows {
			matlabLibraryName := assume(os.join_filename(fmt.aprintf("%sLib", EKHOS_OUTPUT_LIB_NAME), "lib", context.allocator))
		} else when ODIN_OS == .Linux {
			matlabLibraryName := assume(os.join_filename(fmt.aprintf("%sLib", EKHOS_OUTPUT_LIB_NAME), "a", context.allocator))
		}
		matlabPath := assume(os.join_path({INSTALL_LOCATION, MATLAB_DIR, matlabLibraryName}, context.allocator))
		build_log(os.stdout, .Info, fmt.tprintf("Copying %s to %s", libraryOutPath, matlabPath))
		assert(os.copy_file(matlabPath, libraryOutPath))
	}

	return
}

build_test :: proc(options: ^[dynamic]OdinBuildOption) -> (ok := true) {
	assert(check_cmd(ODIN_CMD), fmt.aprintf("Odin Command \"%v\" not found", ODIN_CMD))
	assert(check_cmd(SLANG_CMD), fmt.aprintf("Slang Command \"%v\" not found", SLANG_CMD))

	// Compile Shaders
	for shader in EKHOS_PULSE_ECHO_SHADERS do assert(compile_shader_slangc(shader))

	// Compile PFFFT
	build_pffft() or_return

	outputDir := assume(os.join_path({INSTALL_LOCATION, EKHOS_BINARY_OUT_DIR, EKHOS_OUTPUT_SUBDIR}, context.allocator))
	// Make Output Directory
	if !os.is_directory(outputDir) {
		build_log(os.stdout, .Info, fmt.tprintf("Making Directory %s", outputDir))
		os.make_directory_all(outputDir)
	}

	// Odin Compilation
	when ODIN_OS == .Windows {
		binaryName, _ := os.join_filename(EKHOS_TESTS_NAME, "exe", context.allocator)
	} else when ODIN_OS == .Linux {
		binaryName := EKHOS_TESTS_NAME
	}
	binaryOutPath, _ := os.join_path({outputDir, binaryName}, context.allocator)
	append(options, ..EKHOS_ODIN_TEST_OPTIONS)
	append(options, ..odin_defines_to_options(EKHOS_ODIN_TEST_DEFINES))
	append(options, OdinBuildOption{flag = "out", value = {binaryOutPath}})

	odinCmd := make([dynamic]string)
	append(&odinCmd, ODIN_CMD, ODIN_BUILD_ARG, EKHOS_TEST_DIR)
	append(&odinCmd, ..odin_options_to_args(options[:]))
	assert(assert(run_cmd(odinCmd[:])) == 0)
	return
}

PFFFT_DIRECTORY :: EXTERN_DIRECTORY + "pffft/"
PFFFT_SOURCE :: PFFFT_DIRECTORY + "pffft.c"

append_object_to_static_library :: proc(compilerKind: CompilerKind, libraryPath, objectPath: string) -> (ok := true) {
	if compilerKind == .MSVC {
		combinedLibraryPath := fmt.aprintf("%s.combined", libraryPath)
		command := []string{"lib", fmt.aprintf("/OUT:%s", combinedLibraryPath), libraryPath, objectPath}
		assert(assert(run_cmd(command)) == 0)
		assert(os.copy_file(libraryPath, combinedLibraryPath))
		return
	}

	archiverPath := get_cpp_static_archiver(compilerKind)
	command := []string{archiverPath, "rcs", libraryPath, objectPath}
	assert(assert(run_cmd(command)) == 0)
	return
}

build_pffft :: proc() -> (ok := true) {
	build_log(os.stdout, .Info, "Building PFFFT")
	clone_required_submodules() or_return
	compilerPath, compilerKind := detect_cpp_compiler() or_return
	tmpDirectory := TMP_DIRECTORY + "pffft/"
	optimizationLevel: CppOptimizationLevel = .Debug
	if EKHOS_BUILD_MODE == "release" do optimizationLevel = .Speed
	compileParameters: CppCompileParameters = {
		compilerPath      = compilerPath,
		outputType        = .ObjectFiles,
		sourcePaths       = {PFFFT_SOURCE},
		outputPath        = assume(os.join_path({tmpDirectory, assume(os.join_filename("pffft", get_cpp_object_extension(compilerKind), context.temp_allocator))}, context.temp_allocator)),
		optimizationLevel = optimizationLevel,
		fastMath          = false,
		debug             = EKHOS_BUILD_MODE == "debug",
	}
	compileCmd := build_cpp_compile_command(compilerKind, compileParameters) or_return
	assert(assert(run_cmd(compileCmd)) == 0)
	objectPath := assume(
		os.join_path(
			{tmpDirectory, assume(os.join_filename("pffft", get_cpp_object_extension(compilerKind), context.temp_allocator))},
			context.temp_allocator,
		),
	)
	importDirectory :: IMPORT_DIRECTORY + "pffft/"
	libraryPath := assume(
		os.join_path({importDirectory, assume(os.join_filename("pffft", get_static_library_extensions(ODIN_OS), context.allocator))}, context.allocator),
	)
	archiveParameters: CppArchiveParameters = {
		archiverPath = get_cpp_static_archiver(compilerKind),
		objectFiles  = {objectPath},
		outputPath   = libraryPath,
	}
	archiveCmd := build_cpp_archive_command(compilerKind, archiveParameters) or_return
	assert(assert(run_cmd(archiveCmd)) == 0)
	return
}
