#include <stdint.h>
#include <cstddef>

#ifndef LIB_FN
#if defined(_WIN32)
#define LIB_FN __declspec(dllexport)
#else
#define LIB_FN
#endif
#endif

typedef char byte;
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t i8;
typedef int16_t i16;
typedef int32_t i32;
typedef int64_t i64;
typedef float f32;
typedef double f64;
typedef ptrdiff_t iz;
typedef size_t uz;

template <typename T>
struct Slice {
	T* data;
	iz len;
};

struct Simulator { };

enum class SimulatorType : u32 {
	CPU = 0,
	GPU = 1,
	Hybrid = 2,
};

enum class GpuBackend : u32 {
	Vulkan = 0,
};

struct CpuSettings {
	u32 threadCount;
};

struct GpuSettings {
	GpuBackend backend;
	u32 enableDriverDebugMessages;
};

struct HybridSettings {
  f32 cpuScatterFraction;
};

struct SimulationMetrics {
	f32 simulationTime;
};

struct SimulationSettings {
	f32 samplingFrequency;
	f32 speedOfSound;
	f32 startTime;
	i32 sampleCount;
	u32 cumulative;
	CpuSettings cpuSettings;
	GpuSettings gpuSettings;
  HybridSettings hybridSettings;
	SimulationMetrics simulationMetrics;
};

typedef enum {
	Rectangular = 0,
} ApertureType;

typedef struct {
	f32 apertureInfo[12];
	f32 apertureType;
	f32 apodization;
	f32 delay;
	f32 padding;
} Element;

typedef struct {
	f32 position[3];
	f32 padding0;
	f32 normal[3];
	f32 padding1;
	f32 size[2];
	f32 padding2[2];
} RectangularElement;


typedef struct {
	f32* position;
	f32* normal;
	f32* size;
	f32* apodization;
	f32* delay;
	iz len;
} RectangularElementSoaSlice;

typedef struct {
	i32* index;
	f32* apodization;
	f32* delay;
	iz len;
} TransmissionElementSoaSlice;

typedef TransmissionElementSoaSlice ReceiveChannelElementSoaSlice;

typedef struct {
	TransmissionElementSoaSlice elements;
	u16 impulse;
	u16 excitation;
} Transmission;

typedef struct {
	ReceiveChannelElementSoaSlice elements;
	u16 impulse;
} ReceiveChannel;

typedef Slice<Transmission> TransmissionSlice;
typedef Slice<ReceiveChannel> ReceiveChannelSlice;

typedef struct {
	f32 position[3];
	f32 amplitude;
} Scatter;

typedef Slice<Scatter> ScatterSlice;

typedef Slice<f32> SignalResponse;

typedef Slice<SignalResponse> SignalResponseSlice;

typedef void ( *CLogProc )( void* pUserData, const char* text );
typedef void ( *CAssertProc )( void* pUserData, const char* text );

#ifdef __cplusplus
extern "C" {
#endif

	LIB_FN bool create_cpu_simulator_c(
		Simulator** simulator,
		CLogProc logFunc,
		CAssertProc assertFunc,
		void* pUserData
	);

	LIB_FN void destroy_cpu_simulator_c(
		Simulator* simulator,
		CLogProc logFunc,
		CAssertProc assertFunc,
		void* pUserData
	);

	LIB_FN bool create_vulkan_simulator_c(
		Simulator** simulator,
		SimulationSettings* settings,
		CLogProc logFunc,
		CAssertProc assertFunc,
		void* pUserData
	);

	LIB_FN void destroy_vulkan_simulator_c(
		Simulator* simulator,
		CLogProc logFunc,
		CAssertProc assertFunc,
		void* pUserData
	);

	LIB_FN bool create_hybrid_simulator_c(
		Simulator **simulator, 
		SimulationSettings *settings, 
		CLogProc logFunc, 
		CAssertProc assertFunc, 
		void *pUserData
	);

	LIB_FN void destroy_hybrid_simulator_c(
		Simulator *simulator, 
		CLogProc logFunc, 
		CAssertProc assertFunc, 
		void *pUserData
	);	

	LIB_FN bool plan_simulation_c(
		Simulator* simulator,
		SimulationSettings* settings,
		TransmissionSlice transmissions,
		ReceiveChannelSlice receiveChannels,
		RectangularElementSoaSlice elements,
		ScatterSlice scatters,
		SignalResponseSlice impulses,
		SignalResponseSlice excitations,
		CLogProc logFunc,
		CAssertProc assertFunc,
		void* pUserData
	);

	LIB_FN bool simulate_c(
		Simulator* simulator,
		SimulationSettings* settings,
		TransmissionSlice transmissions,
		ReceiveChannelSlice receiveChannels,
		RectangularElementSoaSlice elements,
		ScatterSlice scatters,
		SignalResponseSlice impulses,
		SignalResponseSlice excitations,
		float* pulseEcho,
		CLogProc logFunc,
		CAssertProc assertFunc,
		void* pUserData
	);

#ifdef __cplusplus
}
#endif
