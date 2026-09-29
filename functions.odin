package ekhos_build

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import util "src/utility"

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

run_cmd :: proc(cmd: []string, working_dir: string = "", broadcast := true) -> (exit_code: int, ok := true) {
	processDesc: os.Process_Desc = {
		command     = cmd,
		working_dir = working_dir,
		stdin       = os.stdin,
		stdout      = os.stdout,
		stderr      = os.stderr,
	}

	if broadcast do build_log(os.stdout, .Command, strings.join(cmd, " "))
	process := is_ok(check(os.process_start(processDesc))) or_return
	state := is_ok(check(os.process_wait(process))) or_return
	exit_code = state.exit_code
	if exit_code != 0 {
		build_log(os.stderr, .Error, fmt.tprintf("Command exited with code %d: %s", exit_code, strings.join(cmd, " ")))
	}
	return
}

when ODIN_OS == .Windows {
	CheckCommand: []string = {"powershell", "-Command", "Get-Command", "cmd", "-ErrorAction", "SilentlyContinue", "|", "Out-Null"}
	CheckCommandPlaceholderIndex: int = 3
} else when ODIN_OS == .Linux {
	CheckCommand: []string = {"which", "cmd"}
	CheckCommandPlaceholderIndex: int = 1
}

check_cmd :: proc(cmd: string) -> (ok: bool) {
	checkCmd := slice.clone(CheckCommand)
	checkCmd[CheckCommandPlaceholderIndex] = cmd
	exit_code := confirm(run_cmd(checkCmd, broadcast = false)) or_return
	return exit_code == 0
}

when ODIN_OS == .Windows {
	UnZipCommand: []string = {"powershell", "-Command", "Expand-Archive", "-Path", "filepath", "-DestinationPath", "destinationpath", "-Force"}
	UnZipPlaceholderIndices: [2]int = {4, 6}
} else when ODIN_OS == .Linux {
	UnZipCommand: []string = {"unzip", "-o", "filepath", "-d", "destinationpath"}
	UnZipPlaceholderIndices: [2]int = {2, 4}
}

unzip_to_folder :: proc(zip_path, dest_folder: string) -> (ok := true) {
	unzipCmd := slice.clone(UnZipCommand)
	unzipCmd[UnZipPlaceholderIndices[0]] = zip_path
	unzipCmd[UnZipPlaceholderIndices[1]] = dest_folder
	confirm(run_cmd(unzipCmd)) or_return
	return
}

/* ----- GH ----- */

GIT_CMD := "git"
GH_CMD := "gh"

clone_submodule :: proc(path: string) -> (ok := true) {
	assert(check_cmd(GIT_CMD), fmt.aprintf("Git Command \"%v\" not found", GIT_CMD))
	cloneCmd := []string{GIT_CMD, "submodule", "update", "--init", "--", path}
	exit_code := confirm(run_cmd(cloneCmd)) or_return
	return exit_code == 0
}

clone_required_submodules :: proc() -> (ok := true) {
	for submodule in EKHOS_REQUIRED_SUBMODULES {
		clone_submodule(submodule) or_return
	}
	return
}

download_release_from_github :: proc(repo, filename: string) -> (ok := true) {
	gh_args: []CliOptions = {
		{flag = "repo", value = repo},
		{flag = "output", value = filename},
		{flag = "pattern", value = "slang-*-windows-x86_64.zip"},
		{flag = "clobber"},
	}

	gh_cmd := make([dynamic]string)
	append(&gh_cmd, ..[]string{GH_CMD, "release", "download"})
	append(&gh_cmd, ..cli_options_to_args(gh_args[:]))
	exit_code := confirm(run_cmd(gh_cmd[:])) or_return
	return exit_code == 0
}

rebuild_needed :: proc(artifact_path: string, source_files: []string) -> (ok: bool) {
	if !os.is_file(artifact_path) {
		return true
	}

	artifact_info := is_ok(os.stat(artifact_path, context.allocator)) or_return
	for src in source_files {
		src_info := is_ok(os.stat(src, context.allocator)) or_return
		if src_info.modification_time._nsec > artifact_info.modification_time._nsec {
			build_log(os.stdout, .Info, fmt.tprintf("Source %s is newer than artifact %s, rebuild required", src, artifact_path))
			return true
		}
	}

	build_log(os.stdout, .Info, fmt.tprintf("Artifact %s is up to date", artifact_path))
	return false
}

/* ----- ODIN ----- */
ODIN_CMD := "odin"
ODIN_BUILD_ARG := "build"
ODIN_TEST_ARG := "test"

OdinBuildOption :: struct {
	flag:  string,
	value: []string,
}

OdinCollection :: struct {
	name: string,
	path: string,
}

OdinDefine :: struct {
	name:  string,
	value: string,
}

odin_defines_to_options :: proc(defines: []OdinDefine) -> (options: []OdinBuildOption) {
	options = make([]OdinBuildOption, len(defines))
	for define, index in defines {
		value := fmt.aprintf("%v=%v", define.name, define.value)
		options[index] = {
			flag  = "define",
			value = slice.from_ptr(new_clone(value), 1),
		}
	}
	return
}

odin_collections_to_options :: proc(collections: []OdinCollection) -> (options: []OdinBuildOption) {
	options = make([]OdinBuildOption, len(collections))
	for collection, index in collections {
		value := fmt.aprintf("%v=%v", collection.name, collection.path)
		options[index] = {
			flag  = "collection",
			value = slice.from_ptr(new_clone(value), 1),
		}
	}
	return
}

odin_options_to_args :: proc(options: []OdinBuildOption) -> (args: []string) {
	args = make([]string, len(options))
	for option, index in options {
		if len(option.value) == 0 {
			args[index] = fmt.aprintf("-%s", option.flag)
		} else {
			args[index] = fmt.aprintf("-%s:%s", option.flag, strings.join(option.value, ","))
		}
	}
	return
}

/* ----- CLI ----- */

CliDefine :: struct {
	define: string,
	value:  string,
}

CliOptions :: struct {
	flag:  CliFlag,
	value: string,
}

CliFlag :: union {
	rune,
	string,
}

cli_options_to_args :: proc(options: []CliOptions) -> (args: []string) {
	dArgs := make([dynamic]string)
	for option in options {
		switch var in option.flag {
		case rune:
			append(&dArgs, fmt.tprintf("-%c", var))
		case string:
			append(&dArgs, fmt.tprintf("--%s", var))
		}
		if len(option.value) > 0 {
			append(&dArgs, option.value)
		}
	}
	args = dArgs[:]
	return
}

cli_defines_to_args :: proc(defines: []CliDefine) -> (args: []string) {
	args = make([]string, len(defines))
	for define, index in defines {
		if len(define.value) == 0 {
			args[index] = fmt.tprintf("-D%s", define.define)
		} else {
			args[index] = fmt.tprintf("-D%s=%s", define.define, define.value)
		}
	}
	return
}

/* ----- C++ ----- */

CPP_COMPILER_KIND: CompilerKind = .GCC

CompilerKind :: enum {
	MSVC,
	Clang,
	GCC,
}

CppDefine :: distinct CliDefine
CppOption :: struct {
	flag:  string,
	value: string,
}

CppCompileParameters :: struct {
	compilerPath:      string,
	outputType:        CppCompileOutputType,
	sourcePaths:       []string,
	outputPath:        string,
	symbolsName:       string,
	includePaths:      []string,
	languageStandard:  string,
	optimizationLevel: CppOptimizationLevel,
	debug:             bool,
	warnings:          bool,
	fastMath:          bool,
	defines:           []CppDefine,
}

CppCompileOutputType :: enum {
	ObjectFiles,
	SharedLibrary,
	Executable,
}

CppOptimizationLevel :: enum {
	Debug, // Debug
	Release, // Standard Release
	Speed, // Maximium Speed
	Size, // Size
}

CppArchiveParameters :: struct {
	archiverPath: string,
	outputPath:   string,
	objectFiles:  []string,
	mode:         string,
}

DEFAULT_ARCHIVE_MODE :: "rcs"

get_cpp_object_extension :: proc(kind: CompilerKind) -> string {
	switch kind {
	case .MSVC:
		return "obj"
	case .Clang:
		fallthrough
	case .GCC:
		return "o"
	}
	return "o"
}

get_static_library_extensions :: proc(platform: runtime.Odin_OS_Type) -> string {
	#partial switch platform {
	case .Windows:
		return "lib"
	case .Darwin:
		fallthrough
	case .Linux:
		return "a"
	}
	build_log(os.stdout, .Error, fmt.tprintf("Invalid Platform %s", platform))
	assert(false)
	return ""
}

detect_cpp_compiler :: proc() -> (path: string, kind: CompilerKind, ok := true) {
	compile := ""
	compilerEnv := os.get_env("CXX", context.allocator)
	if len(compilerEnv) == 0 {
		compilerEnv = os.get_env("CC", context.allocator)
	}
	if len(compilerEnv) > 0 {
		compile = compilerEnv
	}

	if len(compile) == 0 {
		when ODIN_OS == .Windows {
			if check_cmd("cl.exe") {
				compile = "cl.exe"
			} else if check_cmd("clang-cl.exe") {
				compile = "clang-cl.exe"
			} else if check_cmd("clang++") {
				compile = "clang++"
			} else if check_cmd("g++") {
				compile = "g++"
			}
		} else {
			if check_cmd("g++") {
				compile = "g++"
			} else if check_cmd("clang++") {
				compile = "clang++"
			}
		}
	}

	if len(compile) == 0 {
		build_log(os.stderr, .Error, "No C++ compiler found. Set CXX or CC to a valid compiler executable.")
		ok = false
		return
	}

	compiler_lower := strings.to_lower(compile)
	switch {
	case strings.contains(compiler_lower, "clang-cl"):
		kind = .MSVC
	case strings.contains(compiler_lower, "cl.exe") || compiler_lower == "cl":
		kind = .MSVC
	case strings.contains(compiler_lower, "clang"):
		kind = .Clang
	case strings.contains(compiler_lower, "g++") || strings.contains(compiler_lower, "gcc"):
		kind = .GCC
	case ODIN_OS == .Windows:
		kind = .MSVC
	case ODIN_OS == .Linux:
		kind = .GCC
	}
	CPP_COMPILER_KIND = kind
	path = compile
	return
}

get_cpp_static_archiver :: proc(kind: CompilerKind) -> string {
	switch kind {
	case .MSVC:
		return "lib"
	case .Clang:
		fallthrough
	case .GCC:
		return "ar"
	}
	return "ar"
}

build_cpp_compile_command :: proc(compilerKind: CompilerKind, parameters: CppCompileParameters) -> (cmd: []string, ok := true) {
	dCmd := make([dynamic]string)
	append(&dCmd, parameters.compilerPath)

	cppOptions := make([dynamic]CppOption)

	outputPath: string
	switch parameters.outputType {
	case .ObjectFiles:
		append(&cppOptions, CppOption{flag = "c"})
		outputDirectory, outputFilename := os.split_path(parameters.outputPath)
		if !os.is_dir(outputDirectory) {
			build_log(os.stdout, .Info, fmt.tprintf("Making Directory %s", outputDirectory))
			assert(os.make_directory_all(outputDirectory))
		}
		if len(outputFilename) == 0 do outputPath = parameters.outputPath
		else {
			objExt := get_cpp_object_extension(compilerKind)
			if strings.compare(os.ext(outputFilename), fmt.tprintf(".%s", objExt)) == 0 do outputPath = parameters.outputPath
			else if len(outputFilename) > 0 {
				build_log(os.stdout, .Error, fmt.tprintf("Output file %s has an invalid object file extension", outputFilename))
				return {}, false
			} else do outputPath = assume(os.join_path({outputDirectory, assume(os.join_filename(outputFilename, objExt, context.temp_allocator))}, context.temp_allocator))

			if len(parameters.sourcePaths) > 1 {
				build_log(os.stdout, .Error, fmt.tprintf("Cannot specify a single output file %s when there are multiple source files", parameters.outputPath))
				return {}, false
			}
		}
		if compilerKind != .MSVC do append(&cppOptions, CppOption{flag = "fPIC"})
	case .SharedLibrary:
		fallthrough
	case .Executable:
		build_log(os.stdout, .Error, fmt.tprintf("C++ Output Type %s Not Implemented!", parameters.outputType))
	}

	if compilerKind == .MSVC {
		append(&cppOptions, CppOption{flag = "Fo", value = parameters.outputPath})
	} else {
		append(&cppOptions, CppOption{flag = "o", value = parameters.outputPath})
	}

	if len(parameters.languageStandard) > 0 {
		if compilerKind == .MSVC {
			append(&cppOptions, CppOption{flag = fmt.tprintf("std:%s", parameters.languageStandard)})
		} else {
			append(&cppOptions, CppOption{flag = fmt.tprintf("std=%s", parameters.languageStandard)})
		}
	}

	if parameters.warnings {
		if compilerKind == .MSVC do append(&cppOptions, CppOption{flag = "W3"})
		else do append(&cppOptions, CppOption{flag = "Wall"})
	}

	if parameters.debug {
		if compilerKind == .MSVC {
			append(&cppOptions, CppOption{flag = "Zi"})
			pdbFilename := assume(os.join_filename(parameters.symbolsName, "pdb", context.temp_allocator))
			outputDirectory, _ := os.split_path(parameters.outputPath)
			pdbPath := assume(os.join_path({outputDirectory, pdbFilename}, context.temp_allocator))
			append(&cppOptions, CppOption{flag = "Fd", value = pdbPath})
			append(&cppOptions, CppOption{flag = "FS"})
		} else {
			append(&cppOptions, CppOption{flag = "g"})
		}
	}

	switch parameters.optimizationLevel {
	case .Debug:
		if compilerKind == .MSVC do append(&cppOptions, CppOption{flag = "Od"})
		else do append(&cppOptions, CppOption{flag = "O0"})
	case .Release:
		if compilerKind == .MSVC {
			if parameters.debug do build_log(os.stdout, .Warning, "Building with Release optimizations conflicts with debug information!")
			append(&cppOptions, CppOption{flag = "O2"})
		} else {
			if parameters.debug do append(&cppOptions, CppOption{flag = "Og"})
			else do append(&cppOptions, CppOption{flag = "O2"})
		}
	case .Speed:
		if parameters.debug do build_log(os.stdout, .Warning, "Building with Speed optimizations conflicts with debug information!")
		if compilerKind == .MSVC do append(&cppOptions, CppOption{flag = "O2"})
		else do append(&cppOptions, CppOption{flag = "O3"})
	case .Size:
		if parameters.debug do build_log(os.stdout, .Warning, "Building with Size optimizations conflicts with debug information!")
		if compilerKind == .MSVC do append(&cppOptions, CppOption{flag = "Os"})
		else do append(&cppOptions, CppOption{flag = "O1"})
	}

	if parameters.fastMath {
		if compilerKind == .MSVC do append(&cppOptions, CppOption{flag = "fp", value = "fast"})
		else do append(&cppOptions, CppOption{flag = "ffast-math"})
	}

	for include_path in parameters.includePaths {
		if len(include_path) > 0 {
			append(&cppOptions, CppOption{flag = "I", value = include_path})
		}
	}

	append(&dCmd, ..parameters.sourcePaths)
	append(&dCmd, ..cpp_options_to_args(compilerKind, cppOptions[:]))
	append(&dCmd, ..cpp_defines_to_args(compilerKind, parameters.defines))

	cmd = dCmd[:]
	return
}

build_cpp_archive_command :: proc(compilerKind: CompilerKind, parameters: CppArchiveParameters) -> (cmd: []string, ok := true) {
	dCmd := make([dynamic]string)
	append(&dCmd, parameters.archiverPath)

	if compilerKind == .MSVC {
		append(&dCmd, fmt.tprintf("/OUT:%s", parameters.outputPath))
	} else {
		mode := parameters.mode
		if len(mode) == 0 do mode = DEFAULT_ARCHIVE_MODE
		append(&dCmd, mode)
		append(&dCmd, parameters.outputPath)
	}

	for object_file in parameters.objectFiles {
		if len(object_file) > 0 {
			append(&dCmd, object_file)
		}
	}

	cmd = dCmd[:]
	return
}

cpp_defines_to_args :: proc(compilerKind: CompilerKind, defines: []CppDefine) -> (args: []string) {
	args = make([]string, len(defines))
	prefix := "-D"
	if compilerKind == .MSVC {
		prefix = "/D"
	}
	for define, index in defines {
		if len(define.value) == 0 {
			args[index] = fmt.tprintf("%s%s", prefix, define.define)
		} else {
			args[index] = fmt.tprintf("%s%s=%s", prefix, define.define, define.value)
		}
	}
	return
}

cpp_options_to_args :: proc(compilerKind: CompilerKind, options: []CppOption) -> (args: []string) {
	dArgs := make([dynamic]string)
	prefix := "-"
	if compilerKind == .MSVC {
		prefix = "/"
	}
	for option in options {
		flag := option.flag
		if strings.has_prefix(flag, "-") || strings.has_prefix(flag, "/") {
			flag = flag[1:]
		}
		arg := fmt.tprintf("%s%s", prefix, flag)
		if len(option.value) == 0 {
			append(&dArgs, arg)
		} else if compilerKind == .MSVC {
			append(&dArgs, fmt.tprintf("%s%s", arg, option.value))
		} else {
			append(&dArgs, arg, option.value)
		}
	}
	args = dArgs[:]
	return
}

/* ----- SLANGC ----- */
SLANG_CMD := "slangc"

SLANG_INPUT_EXT := "slang"
SLANG_TARGET := "spirv"
SLANG_PROFILE := "spirv_1_4"
SLANG_TARGET_EXT := "spv"
SLANG_SOURCE_SHADER_EXT := "slang"
SLANG_COMPILED_SHADER_EXT := "spv"

SlangShaderType :: enum {
	Graphics,
	Compute,
}

SlangShaderFile :: struct {
	path:         string,
	outputName:   string,
	type:         SlangShaderType,
	capabilities: []string,
	defines:      []CliDefine,
}

compile_shader_slangc :: proc(shader: SlangShaderFile, extraDefines: []CliDefine = {}) -> (ok := true) {
	dir, filename := os.split_path(shader.path)
	moduleName, ext := os.split_filename(filename)
	assert(strings.compare(ext, SLANG_INPUT_EXT) == 0)
	outputModuleName := moduleName
	if len(shader.outputName) > 0 do outputModuleName = shader.outputName
	outputPath := assume(os.join_path({dir, assume(os.join_filename(outputModuleName, SLANG_TARGET_EXT, context.allocator))}, context.allocator))

	slangCmd := make([dynamic]string)
	append(&slangCmd, SLANG_CMD)
	append(&slangCmd, shader.path)
	append(&slangCmd, "-target", SLANG_TARGET)
	append(&slangCmd, "-o", outputPath)
	append(&slangCmd, "-profile", SLANG_PROFILE)
	for capability in shader.capabilities {
		append(&slangCmd, "-capability", capability)
	}

	// NOTE: buffer pointers/push constants rely on scalar (not std430) alignment
	append(&slangCmd, "-fvk-use-scalar-layout")

	// NOTE: debug symbols
	append(&slangCmd, "-g3")

	append(&slangCmd, ..cli_defines_to_args(shader.defines))

	append(&slangCmd, ..cli_defines_to_args(extraDefines))

	confirm((confirm(run_cmd(slangCmd[:])) or_return) == 0) or_return
	return
}

/* ----- GLSLANG ----- */
GLSLANG_CMD := "glslang"

SHADER_COMPILER_CMD := "glslang"
GLSLANG_SOURCE_SHADER_EXT := "hlsl"
GLSLANG_COMPILED_SHADER_EXT := "spv"

GlslangShaderType :: enum {
	Graphics,
	Compute,
}

GlslangShaderFile :: struct {
	path:       string,
	type:       GlslangShaderType,
	entryPoint: string,
}

compile_shader_glslang :: proc(shader: GlslangShaderFile, options: []CliOptions = {}) -> (ok := true) {
	dir, filename := os.split_path(shader.path)
	moduleName, _ := os.split_filename(filename)
	outputFilename := assume(os.join_filename(moduleName, GLSLANG_COMPILED_SHADER_EXT, context.allocator))
	outputPath := assume(os.join_path({dir, outputFilename}, context.allocator))

	glslangCmd := make([dynamic]string)
	append(&glslangCmd, GLSLANG_CMD)
	append(&glslangCmd, shader.path)
	append(&glslangCmd, "-gVS")
	append(&glslangCmd, ..cli_options_to_args({{flag = 'o', value = outputPath}}))
	append(&glslangCmd, ..cli_options_to_args(options))

	run_cmd(glslangCmd[:]) or_return
	return
}
