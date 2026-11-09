package ekhos_build

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:terminal/ansi"
import "core:testing"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

size :: distinct int

LogType :: enum {
	Info,
	Command,
	Generate,
	Warning,
	Error,
}

@(thread_local)
build_local_tz: Maybe(^datetime.TZ_Region)

get_build_local_tz :: proc() -> (tz: ^datetime.TZ_Region, ok := true) {
	tz = build_local_tz.? or_else timezone.region_load("local") or_return
	build_local_tz = tz
	return
}

append_local_time_header :: proc(buf: ^strings.Builder) -> (ok := true) {
	now := time.now()
	defer log.do_time_header({.Date, .Time}, buf, now)

	now_dt := time.time_to_datetime(now) or_return
	local_tz := get_build_local_tz() or_return
	local_dt := timezone.datetime_to_tz(now_dt, local_tz) or_return
	now = time.datetime_to_time(local_dt) or_return
	return
}

build_log :: proc(h: ^os.File, type: LogType, text: string) {
	RESET :: ansi.CSI + ansi.RESET + ansi.SGR

	backing: [1024]byte
	buf := strings.builder_from_bytes(backing[:])

	color := RESET
	typeString := ""
	switch type {
	case .Info:
		color = ansi.CSI + ansi.FG_MAGENTA + ansi.SGR
		typeString = "INFO"
	case .Command:
		color = ansi.CSI + ansi.FG_BLUE + ansi.SGR
		typeString = "COMMAND"
	case .Generate:
		color = ansi.CSI + ansi.FG_GREEN + ansi.SGR
		typeString = "GENERATE"
	case .Warning:
		color = ansi.CSI + ansi.FG_YELLOW + ansi.SGR
		typeString = "WARNING"
	case .Error:
		color = ansi.CSI + ansi.FG_RED + ansi.SGR
		typeString = "ERROR"
	}

	isTerminal := terminal.is_terminal(h)
	isColored := isTerminal && terminal.color_enabled

	if isColored {
		fmt.sbprint(&buf, color)
	}
	fmt.sbprint(&buf, "[")
	fmt.sbprint(&buf, typeString)
	fmt.sbprint(&buf, "] ")

	when time.IS_SUPPORTED {
		append_local_time_header(&buf)
	}

	if isColored {
		fmt.sbprint(&buf, RESET)
	}
	fmt.sbprint(&buf, text)
	fmt.sbprint(&buf, "\n")

	os.write_string(h, strings.to_string(buf))
}

VERIFY_PANIC :: #config(VERIFY_PANIC, true)
VERIFY_FATAL :: #config(VERIFY_FATAL, !VERIFY_PANIC)

CONFIRM_PANIC :: #config(CONFIRM_PANIC, true)
CONFIRM_ERROR :: #config(CONFIRM_ERROR, !CONFIRM_PANIC)
CONFIRM_IGNORE :: #config(CONFIRM_IGNORE, !CONFIRM_PANIC && !CONFIRM_ERROR)

CHECK_WARN :: #config(CHECK_WARN, false)
CHECK_INFO :: #config(CHECK_INFO, !CHECK_WARN && ODIN_DEBUG)
CHECK_IGNORE :: #config(CHECK_IGNORE, !CHECK_WARN && !CHECK_INFO)

ASSERT_PANIC :: #config(ASSERT_PANIC, true)
ASSERT_ERROR :: #config(ASSERT_ERROR, !ASSERT_PANIC)
ASSERT_IGNORE :: #config(ASSERT_IGNORE, !ASSERT_PANIC && !ASSERT_ERROR)

ASSUME_WARN :: #config(ASSUME_WARN, ODIN_DEBUG)
ASSUME_IGNORE :: #config(ASSUME_IGNORE, !ASSUME_WARN)

#assert(VERIFY_PANIC || VERIFY_FATAL, "Invalid setting for verify!")
#assert(CONFIRM_PANIC || CONFIRM_ERROR || CONFIRM_IGNORE, "Invalid setting for confirm!")
#assert(CHECK_WARN || CHECK_INFO || CHECK_IGNORE, "Invalid setting for check!")
#assert(ASSERT_PANIC || ASSERT_ERROR || ASSERT_IGNORE, "Invalid setting for assert!")
#assert(ASSUME_WARN || ASSUME_IGNORE, "Invalid setting for assume!")

emit_assert_log :: #force_inline proc(level: LogType, message: string, loc: runtime.Source_Code_Location, detail: ..any) {
	text := message
	if len(detail) > 0 {
		text = fmt.tprintf("%s (%v)", message, detail[0])
	}
	file := os.stderr
	if level == .Info {
		file = os.stdout
	}
	build_log(file, level, text)
}

ignore :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {  }

info :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok { return }
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		emit_assert_log(.Info, message, loc, ..detail)
	}
	internal(message, loc, ..detail)
}

warn :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok { return }
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		emit_assert_log(.Warning, message, loc, ..detail)
	}
	internal(message, loc, ..detail)
}

error :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok { return }
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		emit_assert_log(.Error, message, loc, ..detail)
	}
	internal(message, loc, ..detail)
}

panic :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok { return }
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		emit_assert_log(.Error, message, loc, ..detail)
		runtime.panic("assert.panic", loc)
	}
	internal(message, loc, ..detail)
}

fatal :: #force_inline proc(ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok { return }
	@(cold)
	internal :: proc(message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		emit_assert_log(.Error, message, loc, ..detail)
	}
	internal(message, loc, ..detail)
}

test :: #force_inline proc(t: ^testing.T, ok: bool, message: string, loc := #caller_location, detail: ..any) {
	if ok { return }
	@(cold)
	internal :: proc(t: ^testing.T, ok: bool, message: string, loc: runtime.Source_Code_Location, detail: ..any) {
		if len(detail) > 0 { testing.expectf(t, ok, "%s (%v)", message, detail[0], loc = loc) } else { testing.expectf(t, ok, message, loc = loc) }
	}
	internal(t, ok, message, loc, ..detail)
}

@(cold)
fail :: #force_inline proc(message := "", loc := #caller_location) -> ! {
	emit_assert_log(.Error, message, loc)
	runtime.panic("assert.fail", loc)
}

not_implemented :: #force_inline proc() -> ! { fail("Not Implemented!") }

ensure :: proc {
	ensure_bool_zero,
	ensure_bool_one,
	ensure_bool_two,
	ensure_bool_three,
	ensure_bool_four,
	ensure_enum_zero,
	ensure_enum_one,
	ensure_enum_two,
	ensure_enum_three,
	ensure_enum_four,
	ensure_union_zero,
	ensure_union_one,
	ensure_union_two,
	ensure_union_three,
	ensure_union_four,
	ensure_rawptr,
	ensure_size,
}

verify :: proc {
	verify_bool_zero,
	verify_bool_one,
	verify_bool_two,
	verify_bool_three,
	verify_bool_four,
	verify_enum_zero,
	verify_enum_one,
	verify_enum_two,
	verify_enum_three,
	verify_enum_four,
	verify_union_zero,
	verify_union_one,
	verify_union_two,
	verify_union_three,
	verify_union_four,
	verify_rawptr,
	verify_size,
}

confirm :: proc {
	confirm_bool_zero,
	confirm_bool_one,
	confirm_bool_two,
	confirm_bool_three,
	confirm_bool_four,
	confirm_enum_zero,
	confirm_enum_one,
	confirm_enum_two,
	confirm_enum_three,
	confirm_enum_four,
	confirm_union_zero,
	confirm_union_one,
	confirm_union_two,
	confirm_union_three,
	confirm_union_four,
	confirm_rawptr,
	confirm_size,
}

check :: proc {
	check_bool_zero,
	check_bool_one,
	check_bool_two,
	check_bool_three,
	check_bool_four,
	check_enum_zero,
	check_enum_one,
	check_enum_two,
	check_enum_three,
	check_enum_four,
	check_union_zero,
	check_union_one,
	check_union_two,
	check_union_three,
	check_union_four,
	check_rawptr,
	check_size,
}

assert :: proc {
	assert_bool_zero,
	assert_bool_one,
	assert_bool_two,
	assert_bool_three,
	assert_bool_four,
	assert_enum_zero,
	assert_enum_one,
	assert_enum_two,
	assert_enum_three,
	assert_enum_four,
	assert_union_zero,
	assert_union_one,
	assert_union_two,
	assert_union_three,
	assert_union_four,
	assert_rawptr,
	assert_size,
}

assume :: proc {
	assume_bool_zero,
	assume_bool_one,
	assume_bool_two,
	assume_bool_three,
	assume_bool_four,
	assume_enum_zero,
	assume_enum_one,
	assume_enum_two,
	assume_enum_three,
	assume_enum_four,
	assume_union_zero,
	assume_union_one,
	assume_union_two,
	assume_union_three,
	assume_union_four,
	assume_rawptr,
	assume_size,
}

is_ok :: proc {
	is_ok_enum_zero,
	is_ok_enum_one,
	is_ok_enum_two,
	is_ok_enum_three,
	is_ok_enum_four,
	is_ok_union_zero,
	is_ok_union_one,
	is_ok_union_two,
	is_ok_union_three,
	is_ok_union_four,
}

ensure_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) where intrinsics.type_is_boolean(B) {
	panic(bool(condition), message, loc)
}

ensure_bool_one :: #force_inline proc(value: $T, ok: $B, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_boolean(B) {
	panic(bool(ok), message, loc)
	return value
}

ensure_bool_two :: #force_inline proc(first: $A, second: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	panic(bool(ok), message, loc)
	return first, second
}

ensure_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_boolean(D) {
	panic(bool(ok), message, loc)
	return first, second, third
}

ensure_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_boolean(E) {
	panic(bool(ok), message, loc)
	return first, second, third, fourth
}

ensure_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
}

ensure_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return value
}

ensure_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return first, second
}

ensure_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return first, second, third
}

ensure_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_enum(E) {
	panic(cast(int)err == 0, message, loc, err)
	return first, second, third, fourth
}

ensure_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
}

ensure_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return value
}

ensure_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return first, second
}

ensure_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return first, second, third
}

ensure_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	panic(err == E{}, message, loc, err)
	return first, second, third, fourth
}

ensure_rawptr :: #force_inline proc(value: rawptr, message := "", loc := #caller_location) {
	panic(value != nil, message, loc, value)
}

ensure_size :: #force_inline proc(#any_int value: size, message := "", loc := #caller_location) {
	panic(value > 0, message, loc, value)
}

@(require_results)
verify_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	when VERIFY_PANIC {
		panic(bool(condition), message, loc)
	} else when VERIFY_FATAL {
		fatal(bool(condition), message, loc)
	}
	return bool(condition)
}

@(require_results)
verify_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) {
	when VERIFY_PANIC {
		panic(bool(ok), message, loc)
	} else when VERIFY_FATAL {
		fatal(bool(ok), message, loc)
	}
	return value, bool(ok)
}

@(require_results)
verify_bool_two :: #force_inline proc(
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when VERIFY_PANIC {
		panic(bool(ok), message, loc)
	} else when VERIFY_FATAL {

		fatal(bool(ok), message, loc)
	}
	return first, second, bool(ok)
}

verify_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	when VERIFY_PANIC {
		panic(bool(ok), message, loc)
	} else when VERIFY_FATAL {
		fatal(bool(ok), message, loc)
	}
	return first, second, third, bool(ok)
}

@(require_results)
verify_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	when VERIFY_PANIC {
		panic(bool(ok), message, loc)
	} else when VERIFY_FATAL {
		fatal(bool(ok), message, loc)
	}
	return first, second, third, fourth, bool(ok)
}

@(require_results)
verify_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_enum(E) {
	when VERIFY_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(cast(int)err == 0, message, loc, err)
	}
	return err
}

@(require_results)
verify_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> (T, E) where intrinsics.type_is_enum(E) {
	when VERIFY_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(cast(int)err == 0, message, loc, err)
	}
	return value, err
}

@(require_results)
verify_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_enum(E) {
	when VERIFY_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(cast(int)err == 0, message, loc, err)
	}
	return first, second, err
}

verify_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_enum(E) {
	when VERIFY_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, err
}

@(require_results)
verify_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_enum(E) {
	when VERIFY_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth, err
}

@(require_results)
verify_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when VERIFY_PANIC {
		panic(err == E{}, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(err == E{}, message, loc, err)
	}
	return err
}

@(require_results)
verify_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VERIFY_PANIC {
		panic(err == E{}, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(err == E{}, message, loc, err)
	}
	return value, err
}
@(require_results)
verify_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VERIFY_PANIC {
		panic(err == E{}, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(err == E{}, message, loc, err)
	}
	return first, second, err
}

@(require_results)
verify_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when VERIFY_PANIC {
		panic(err == E{}, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(err == E{}, message, loc, err)
	}
	return first, second, third, err
}

@(require_results)
verify_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when VERIFY_PANIC {
		panic(err == E{}, message, loc, err)
	} else when VERIFY_FATAL {
		fatal(err == E{}, message, loc, err)
	}
	return first, second, third, fourth, err
}

@(require_results)
verify_rawptr :: #force_inline proc(value: rawptr, message := "", loc := #caller_location) -> (rawptr, bool) {
	when VERIFY_PANIC {
		panic(value != nil, message, loc, value)
	} else when VERIFY_FATAL {
		fatal(value != nil, message, loc, value)
	}
	return value, value != nil
}

@(require_results)
verify_size :: #force_inline proc(#any_int value: size, message := "", loc := #caller_location) -> (size, bool) {
	when VERIFY_PANIC {
		panic(value > 0, message, loc, value)
	} else when VERIFY_FATAL {
		fatal(value > 0, message, loc, value)
	}
	return value, value > 0
}

confirm_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	when CONFIRM_PANIC {
		panic(bool(condition), message, loc)
	} else when CONFIRM_ERROR {
		error(bool(condition), message, loc)
	} else when CONFIRM_IGNORE {
		ignore(bool(condition), message, loc)
	}
	return bool(condition)
}

confirm_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) {
	when CONFIRM_PANIC {
		panic(bool(ok), message, loc)
	} else when CONFIRM_ERROR {
		error(bool(ok), message, loc)
	} else when CONFIRM_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return value, bool(ok)
}

confirm_bool_two :: #force_inline proc(
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when CONFIRM_PANIC {
		panic(bool(ok), message, loc)
	} else when CONFIRM_ERROR {
		error(bool(ok), message, loc)
	} else when CONFIRM_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, bool(ok)
}

confirm_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	when CONFIRM_PANIC {
		panic(bool(ok), message, loc)
	} else when CONFIRM_ERROR {
		error(bool(ok), message, loc)
	} else when CONFIRM_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third, bool(ok)
}

confirm_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	when CONFIRM_PANIC {
		panic(bool(ok), message, loc)
	} else when CONFIRM_ERROR {
		error(bool(ok), message, loc)
	} else when CONFIRM_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third, fourth, bool(ok)
}

confirm_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_enum(E) {
	when CONFIRM_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return err
}

confirm_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> (T, E) where intrinsics.type_is_enum(E) {
	when CONFIRM_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return value, err
}

confirm_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_enum(E) {
	when CONFIRM_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, err
}

confirm_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_enum(E) {
	when CONFIRM_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, err
}

confirm_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_enum(E) {
	when CONFIRM_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth, err
}

confirm_union_zero :: #force_inline proc(
	err: $E,
	message := "",
	loc := #caller_location,
) -> E where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when CONFIRM_PANIC {
		panic(err == E{}, message, loc, err)
	} else when CONFIRM_ERROR {
		error(err == E{}, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return err
}

confirm_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when CONFIRM_PANIC {
		panic(err == E{}, message, loc, err)
	} else when CONFIRM_ERROR {
		error(err == E{}, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return value, err
}

confirm_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when CONFIRM_PANIC {
		panic(err == E{}, message, loc, err)
	} else when CONFIRM_ERROR {
		error(err == E{}, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, err
}

confirm_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when CONFIRM_PANIC {
		panic(err == E{}, message, loc, err)
	} else when CONFIRM_ERROR {
		error(err == E{}, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third, err
}

confirm_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when CONFIRM_PANIC {
		panic(err == E{}, message, loc, err)
	} else when CONFIRM_ERROR {
		error(err == E{}, message, loc, err)
	} else when CONFIRM_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third, fourth, err
}

confirm_rawptr :: #force_inline proc(value: rawptr, message := "", loc := #caller_location) -> (rawptr, bool) {
	when CONFIRM_PANIC {
		panic(value != nil, message, loc, value)
	} else when CONFIRM_ERROR {
		error(value != nil, message, loc, value)
	} else when CONFIRM_IGNORE {
		ignore(value != nil, message, loc, value)
	}
	return value, value != nil
}

confirm_size :: #force_inline proc(#any_int value: size, message := "", loc := #caller_location) -> (size, bool) {
	when CONFIRM_PANIC {
		panic(value > 0, message, loc, value)
	} else when CONFIRM_ERROR {
		error(value > 0, message, loc, value)
	} else when CONFIRM_IGNORE {
		ignore(value > 0, message, loc, value)
	}
	return value, value > 0
}

check_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) -> bool where intrinsics.type_is_boolean(B) {
	when CHECK_WARN {
		warn(bool(condition), message, loc)
	} else when CHECK_INFO {
		info(bool(condition), message, loc)
	} else when CHECK_IGNORE {
		ignore(bool(condition), message, loc)
	}
	return bool(condition)
}

check_bool_one :: #force_inline proc(
	value: $T,
	ok: $B,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	bool,
) where intrinsics.type_is_boolean(B) {
	when CHECK_WARN {
		warn(bool(ok), message, loc)
	} else when CHECK_INFO {
		info(bool(ok), message, loc)
	} else when CHECK_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return value, bool(ok)
}

check_bool_two :: #force_inline proc(
	first: $A,
	second: $B,
	ok: $C,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	bool,
) where intrinsics.type_is_boolean(C) {
	when CHECK_WARN {
		warn(bool(ok), message, loc)
	} else when CHECK_INFO {
		info(bool(ok), message, loc)
	} else when CHECK_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, bool(ok)
}

check_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	bool,
) where intrinsics.type_is_boolean(D) {
	when CHECK_WARN {
		warn(bool(ok), message, loc)
	} else when CHECK_INFO {
		info(bool(ok), message, loc)
	} else when CHECK_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third, bool(ok)
}

check_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	bool,
) where intrinsics.type_is_boolean(E) {
	when CHECK_WARN {
		warn(bool(ok), message, loc)
	} else when CHECK_INFO {
		info(bool(ok), message, loc)
	} else when CHECK_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third, fourth, bool(ok)
}

check_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_enum(E) {
	when CHECK_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when CHECK_INFO {
		info(cast(int)err == 0, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return err
}

check_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> (T, E) where intrinsics.type_is_enum(E) {
	when CHECK_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when CHECK_INFO {
		info(cast(int)err == 0, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return value, err
}

check_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_enum(E) {
	when CHECK_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when CHECK_INFO {
		info(cast(int)err == 0, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, err
}

check_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_enum(E) {
	when CHECK_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when CHECK_INFO {
		info(cast(int)err == 0, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, err
}

check_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_enum(E) {
	when CHECK_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when CHECK_INFO {
		info(cast(int)err == 0, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth, err
}

check_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) -> E where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when CHECK_WARN {
		warn(err == E{}, message, loc, err)
	} else when CHECK_INFO {
		info(err == E{}, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return err
}

check_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	T,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when CHECK_WARN {
		warn(err == E{}, message, loc, err)
	} else when CHECK_INFO {
		info(err == E{}, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return value, err
}

check_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when CHECK_WARN {
		warn(err == E{}, message, loc, err)
	} else when CHECK_INFO {
		info(err == E{}, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, err
}

check_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	E,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when CHECK_WARN {
		warn(err == E{}, message, loc, err)
	} else when CHECK_INFO {
		info(err == E{}, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third, err
}

check_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
	E,
) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when CHECK_WARN {
		warn(err == E{}, message, loc, err)
	} else when CHECK_INFO {
		info(err == E{}, message, loc, err)
	} else when CHECK_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third, fourth, err
}

check_rawptr :: #force_inline proc(value: rawptr, message := "", loc := #caller_location) -> (rawptr, bool) {
	when CHECK_WARN {
		warn(value != nil, message, loc, value)
	} else when CHECK_INFO {
		info(value != nil, message, loc, value)
	} else when CHECK_IGNORE {
		ignore(value != nil, message, loc, value)
	}
	return value, value != nil
}

check_size :: #force_inline proc(#any_int value: size, message := "", loc := #caller_location) -> (size, bool) {
	when CHECK_WARN {
		warn(value > 0, message, loc, value)
	} else when CHECK_INFO {
		info(value > 0, message, loc, value)
	} else when CHECK_IGNORE {
		ignore(value > 0, message, loc, value)
	}
	return value, value > 0
}

assert_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) where intrinsics.type_is_boolean(B) {
	when ASSERT_PANIC {
		panic(bool(condition), message, loc)
	} else when ASSERT_ERROR {
		error(bool(condition), message, loc)
	} else when ASSERT_IGNORE {
		ignore(bool(condition), message, loc)
	}
}

assert_bool_one :: #force_inline proc(value: $T, ok: $B, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_boolean(B) {
	when ASSERT_PANIC {
		panic(bool(ok), message, loc)
	} else when ASSERT_ERROR {
		error(bool(ok), message, loc)
	} else when ASSERT_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return value
}

assert_bool_two :: #force_inline proc(first: $A, second: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	when ASSERT_PANIC {
		panic(bool(ok), message, loc)
	} else when ASSERT_ERROR {
		error(bool(ok), message, loc)
	} else when ASSERT_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second
}

assert_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_boolean(D) {
	when ASSERT_PANIC {
		panic(bool(ok), message, loc)
	} else when ASSERT_ERROR {
		error(bool(ok), message, loc)
	} else when ASSERT_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third
}

assert_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_boolean(E) {
	when ASSERT_PANIC {
		panic(bool(ok), message, loc)
	} else when ASSERT_ERROR {
		error(bool(ok), message, loc)
	} else when ASSERT_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third, fourth
}

assert_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_enum(E) {
	when ASSERT_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when ASSERT_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
}

assert_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_enum(E) {
	when ASSERT_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when ASSERT_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return value
}

assert_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_enum(E) {
	when ASSERT_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when ASSERT_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second
}

assert_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_enum(E) {
	when ASSERT_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when ASSERT_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third
}

assert_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_enum(E) {
	when ASSERT_PANIC {
		panic(cast(int)err == 0, message, loc, err)
	} else when ASSERT_ERROR {
		error(cast(int)err == 0, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth
}

assert_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when ASSERT_PANIC {
		panic(err == E{}, message, loc, err)
	} else when ASSERT_ERROR {
		error(err == E{}, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
}

assert_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> T where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when ASSERT_PANIC {
		panic(err == E{}, message, loc, err)
	} else when ASSERT_ERROR {
		error(err == E{}, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return value
}

assert_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when ASSERT_PANIC {
		panic(err == E{}, message, loc, err)
	} else when ASSERT_ERROR {
		error(err == E{}, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second
}

assert_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when ASSERT_PANIC {
		panic(err == E{}, message, loc, err)
	} else when ASSERT_ERROR {
		error(err == E{}, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third
}

assert_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when ASSERT_PANIC {
		panic(err == E{}, message, loc, err)
	} else when ASSERT_ERROR {
		error(err == E{}, message, loc, err)
	} else when ASSERT_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third, fourth
}

assert_rawptr :: #force_inline proc(value: rawptr, message := "", loc := #caller_location) {
	when ASSERT_PANIC {
		panic(value != nil, message, loc, value)
	} else when ASSERT_ERROR {
		error(value != nil, message, loc, value)
	} else when ASSERT_IGNORE {
		ignore(value != nil, message, loc, value)
	}
}

assert_size :: #force_inline proc(#any_int value: size, message := "", loc := #caller_location) {
	when ASSERT_PANIC {
		panic(value > 0, message, loc, value)
	} else when ASSERT_ERROR {
		error(value > 0, message, loc, value)
	} else when ASSERT_IGNORE {
		ignore(value > 0, message, loc, value)
	}
}

assume_bool_zero :: #force_inline proc(condition: $B, message := "", loc := #caller_location) where intrinsics.type_is_boolean(B) {
	when ASSUME_WARN {
		warn(bool(condition), message, loc)
	} else when ASSUME_IGNORE {
		ignore(bool(condition), message, loc)
	}
}

assume_bool_one :: #force_inline proc(value: $T, ok: $B, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_boolean(B) {
	when ASSUME_WARN {
		warn(bool(ok), message, loc)
	} else when ASSUME_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return value
}

assume_bool_two :: #force_inline proc(first: $A, second: $B, ok: $C, message := "", loc := #caller_location) -> (A, B) where intrinsics.type_is_boolean(C) {
	when ASSUME_WARN {
		warn(bool(ok), message, loc)
	} else when ASSUME_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second
}

assume_bool_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	ok: $D,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_boolean(D) {
	when ASSUME_WARN {
		warn(bool(ok), message, loc)
	} else when ASSUME_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third
}

assume_bool_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	ok: $E,
	message := "",
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_boolean(E) {
	when ASSUME_WARN {
		warn(bool(ok), message, loc)
	} else when ASSUME_IGNORE {
		ignore(bool(ok), message, loc)
	}
	return first, second, third, fourth
}

assume_enum_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_enum(E) {
	when ASSUME_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
}

assume_enum_one :: #force_inline proc(value: $T, err: $E, message := #caller_expression, loc := #caller_location) -> T where intrinsics.type_is_enum(E) {
	when ASSUME_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return value
}

assume_enum_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_enum(E) {
	when ASSUME_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second
}

assume_enum_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_enum(E) {
	when ASSUME_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third
}

assume_enum_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_enum(E) {
	when ASSUME_WARN {
		warn(cast(int)err == 0, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(cast(int)err == 0, message, loc, err)
	}
	return first, second, third, fourth
}

assume_union_zero :: #force_inline proc(err: $E, message := "", loc := #caller_location) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when ASSUME_WARN {
		warn(err == E{}, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
}

assume_union_one :: #force_inline proc(
	value: $T,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> T where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when ASSUME_WARN {
		warn(err == E{}, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return value
}

assume_union_two :: #force_inline proc(
	first: $A,
	second: $B,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when ASSUME_WARN {
		warn(err == E{}, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second
}

assume_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
) where intrinsics.type_is_union(E) &&
	intrinsics.type_has_nil(E) {
	when ASSUME_WARN {
		warn(err == E{}, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third
}

assume_union_four :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	fourth: $D,
	err: $E,
	message := #caller_expression,
	loc := #caller_location,
) -> (
	A,
	B,
	C,
	D,
) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	when ASSUME_WARN {
		warn(err == E{}, message, loc, err)
	} else when ASSUME_IGNORE {
		ignore(err == E{}, message, loc, err)
	}
	return first, second, third, fourth
}

assume_rawptr :: #force_inline proc(value: rawptr, message := "", loc := #caller_location) {
	when ASSUME_WARN {
		warn(value != nil, message, loc, value)
	} else when ASSUME_IGNORE {
		ignore(value != nil, message, loc, value)
	}
}

assume_size :: #force_inline proc(#any_int value: size, message := "", loc := #caller_location) {
	when ASSUME_WARN {
		warn(value > 0, message, loc, value)
	} else when ASSUME_IGNORE {
		ignore(value > 0, message, loc, value)
	}
}

is_ok_enum_zero :: #force_inline proc(err: $E) -> bool where intrinsics.type_is_enum(E) {
	return cast(int)err == 0
}

is_ok_enum_one :: #force_inline proc(value: $T, err: $E) -> (T, bool) where intrinsics.type_is_enum(E) {
	return value, cast(int)err == 0
}

is_ok_enum_two :: #force_inline proc(first: $A, second: $B, err: $E) -> (A, B, bool) where intrinsics.type_is_enum(E) {
	return first, second, cast(int)err == 0
}

is_ok_enum_three :: #force_inline proc(first: $A, second: $B, third: $C, err: $E) -> (A, B, C, bool) where intrinsics.type_is_enum(E) {
	return first, second, third, cast(int)err == 0
}

is_ok_enum_four :: #force_inline proc(first: $A, second: $B, third: $C, fourth: $D, err: $E) -> (A, B, C, D, bool) where intrinsics.type_is_enum(E) {
	return first, second, third, fourth, cast(int)err == 0
}

is_ok_union_zero :: #force_inline proc(err: $E) -> bool where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return err == E{}
}

is_ok_union_one :: #force_inline proc(value: $T, err: $E) -> (T, bool) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return value, err == E{}
}

is_ok_union_two :: #force_inline proc(first: $A, second: $B, err: $E) -> (A, B, bool) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return first, second, err == E{}
}

is_ok_union_three :: #force_inline proc(
	first: $A,
	second: $B,
	third: $C,
	err: $E,
) -> (A, B, C, bool) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return first, second, third, err == E{}
}

is_ok_union_four :: #force_inline proc(first: $A, second: $B, third: $C, fourth: $D, err: $E) -> (A, B, C, D, bool) where intrinsics.type_is_union(E) && intrinsics.type_has_nil(E) {
	return first, second, third, fourth, err == E{}
}
