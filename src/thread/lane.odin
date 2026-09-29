package ekhos_thread

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:sync"

Lane :: struct {
	active:  bool,
	idx:     int,
	count:   int,
	syncPtr: ^rawptr,
	barrier: ^sync.Barrier,
}

open_lane_group :: proc(laneCount: int, allocator := context.temp_allocator) -> (lanes: []Lane) {
	log.assert(laneCount > 0)
	lanes = make([]Lane, laneCount, allocator)
	syncPtr := new(rawptr, allocator)
	barrier := new(sync.Barrier, allocator)
	sync.barrier_init(barrier, laneCount)
	for &lane, index in lanes {
		lane = {
			active  = true,
			idx     = index,
			count   = laneCount,
			syncPtr = syncPtr,
			barrier = barrier,
		}
	}
	return
}

close_lane_group :: proc(laneCount: int, allocator := context.temp_allocator, lanes: []Lane) {
	assert(laneCount > 0)
	free(lanes[0].syncPtr, allocator)
	free(lanes[0].barrier, allocator)
}

@(deferred_in_out = close_lane_subgroup)
open_lane_subgroup :: proc(lane: ^Lane, minLane, laneCount: int, allocator := context.temp_allocator) -> (oldLane: Lane) {
	if lane == nil { return }
	oldLane = lane^
	if active := laneActive(lane); active {
		if laneIdx(lane) >= minLane && laneIdx(lane) < minLane + laneCount {
			lane.idx -= minLane
			lane.count = laneCount
		} else {
			lane.active = false
		}

		syncPtr: ^rawptr
		barrier: ^sync.Barrier
		if laneIdx(lane) == 0 {
			syncPtr = new(rawptr, allocator)
			barrier = new(sync.Barrier, allocator)
			sync.barrier_init(barrier, laneCount)
		}
		laneSyncValue(lane, minLane, &syncPtr)
		laneSyncValue(lane, minLane, &barrier)

		lane.syncPtr = syncPtr
		lane.barrier = barrier
	}
	return
}

close_lane_subgroup :: proc(lane: ^Lane, minLane, laneCount: int, allocator := context.temp_allocator, oldLane: Lane) {
	if lane == nil { return }
	if laneIdx(lane) == 0 {
		free(lane.syncPtr, allocator)
		free(lane.barrier, allocator)
	}
	lane^ = oldLane
}

laneActive :: #force_inline proc(lane: ^Lane) -> (active: bool) {
	if lane == nil { return }
	return lane.active
}

laneIdx :: #force_inline proc(lane: ^Lane) -> (index: int) {
	if lane == nil { return }
	return lane.idx
}

laneCount :: #force_inline proc(lane: ^Lane) -> (count: int) {
	if lane == nil { return 1 }
	return lane.count
}

laneRange :: #force_inline proc(lane: ^Lane, #any_int count: int) -> (startIndex, endIndex: int, found: bool) {
	if active := laneActive(lane); active && count >= 0 {
		valuesPerThread := count / lane.count
		leftoverValuesCount := count % lane.count
		leftoversBeforeThisThread := min(lane.idx, leftoverValuesCount)
		startIndex = valuesPerThread * lane.idx + leftoversBeforeThisThread
		endIndex = startIndex + valuesPerThread + (lane.idx < leftoverValuesCount ? 1 : 0)
		found = true
	}
	return
}

laneSync :: #force_inline proc(lane: ^Lane) {
	if active := laneActive(lane); active {
		sync.barrier_wait(lane.barrier)
	}
}

laneSyncValue :: #force_inline proc(lane: ^Lane, #any_int broadcastLane: int, value: ^$T, #any_int count := 1) {
	if active := laneActive(lane); active && broadcastLane >= 0 && broadcastLane < laneCount(lane) {
		if laneIdx(lane) == broadcastLane {
			lane.syncPtr^ = value
		}
		laneSync(lane)
		if lane.idx != broadcastLane {
			runtime.mem_copy_non_overlapping(value, lane.syncPtr^, size_of(T) * count)
		}
		laneSync(lane)
	}
}
