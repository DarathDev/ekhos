#include "ekhosLib.hpp"
#include "mex.hpp"
#include "mexAdapter.hpp"
#include <algorithm>
#include <cstring>
#include <functional>
#include <stdint.h>
#include <stdexcept>
#include <vector>

using namespace matlab::data;
using matlab::mex::ArgumentList;

static void printLogger(void* pUserData, const char* text) {
	auto* function = static_cast<matlab::mex::Function*>( pUserData );
	if (function != nullptr) {
		std::cout << text << std::endl;
	}
}

static void throwAssertion(void* pUserData, const char* text) {
	throw std::runtime_error(text != nullptr ? text : "Odin assertion failed");
}

static void freeRectangularElementSoaSlice(RectangularElementSoaSlice* slice) {
	if (slice == nullptr) {
		return;
	}
	delete[ ] slice->position;
	delete[ ] slice->normal;
	delete[ ] slice->size;
	delete[ ] slice->apodization;
	delete[ ] slice->delay;
	slice->position = nullptr;
	slice->normal = nullptr;
	slice->size = nullptr;
	slice->apodization = nullptr;
	slice->delay = nullptr;
	slice->len = 0;
}

static void freeTransmissionSlice(TransmissionSlice* transmissions) {
	if (transmissions == nullptr || transmissions->data == nullptr) {
		return;
	}
	for (iz i = 0; i < transmissions->len; ++i) {
		Transmission transmission = transmissions->data[i];
		delete[ ] transmission.elements.index;
		delete[ ] transmission.elements.apodization;
		delete[ ] transmission.elements.delay;
	}
	delete[ ] transmissions->data;
	transmissions->data = nullptr;
	transmissions->len = 0;
}

static void freeReceiveChannelSlice(ReceiveChannelSlice* receiveChannels) {
	if (receiveChannels == nullptr || receiveChannels->data == nullptr) {
		return;
	}
	for (iz i = 0; i < receiveChannels->len; ++i) {
		delete[ ] receiveChannels->data[i].elements.index;
		delete[ ] receiveChannels->data[i].elements.apodization;
		delete[ ] receiveChannels->data[i].elements.delay;
	}
	delete[ ] receiveChannels->data;
	receiveChannels->data = nullptr;
	receiveChannels->len = 0;
}

static void freeSignalResponseSlice(SignalResponseSlice* responses) {
	if (responses == nullptr || responses->data == nullptr) {
		return;
	}
	for (iz i = 0; i < responses->len; ++i) {
		delete[ ] responses->data[i].data;
	}
	delete[ ] responses->data;
	responses->data = nullptr;
	responses->len = 0;
}

template <typename T> const T* getDataPtr(matlab::data::Array arr) {
	const matlab::data::TypedArray<T> arr_t = arr;
	matlab::data::TypedIterator<const T> it(arr_t.begin());
	return it.operator->();
}

class MexFunction : public matlab::mex::Function {
	std::ostringstream outputStream;

public:
	void operator()(matlab::mex::ArgumentList outputs,
					matlab::mex::ArgumentList inputs) {
		void mexLock();

		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		ArrayFactory factory;

		checkArguments(outputs, inputs);
		ObjectArray mxSimulator(inputs[0]);

		SimulationSettings settings;
		SimulatorType simulatorType;
		RectangularElementSoaSlice elements;
		TransmissionSlice transmissions;
		ReceiveChannelSlice receiveChannels;
		ScatterSlice scatters;
		SignalResponseSlice impulses;
		SignalResponseSlice excitations;

		readSimulationInputs(mxSimulator, settings, simulatorType,
			elements, transmissions, receiveChannels, scatters, impulses, excitations);

		Simulator* simulator;
		switch (simulatorType) {
		case SimulatorType::CPU:
			create_cpu_simulator_c(&simulator, printLogger, throwAssertion, this);
			break;
		case SimulatorType::GPU:
			create_vulkan_simulator_c(
				&simulator,
				&settings,
				printLogger,
				throwAssertion,
				this
			);
			break;
		case SimulatorType::Hybrid:
			create_hybrid_simulator_c(&simulator, &settings, printLogger, throwAssertion, this);
			break;
		}

		plan_simulation_c(simulator, &settings, transmissions, receiveChannels, elements,
					  scatters, impulses, excitations, printLogger, throwAssertion, this);
		matlabPtr->setProperty(mxSimulator, u"StartTime",
						   factory.createScalar<f32>(settings.startTime));
		matlabPtr->setProperty(mxSimulator, u"SampleCount",
						   factory.createScalar<u32>(settings.sampleCount));

		auto pulseEchoBuffer = factory.createBuffer<float>(
			settings.sampleCount * receiveChannels.len * transmissions.len);

		simulate_c(simulator, &settings, transmissions, receiveChannels, elements,
				   scatters, impulses, excitations, pulseEchoBuffer.get(), printLogger,
				   throwAssertion, this);
		ObjectArray mxMetrics = matlabPtr->getProperty(mxSimulator, u"Metrics");
		matlabPtr->setProperty(mxMetrics, u"SimulationTime",
							   factory.createScalar<f32>(settings.simulationMetrics.simulationTime));
		matlabPtr->setProperty(mxSimulator, u"Metrics", mxMetrics);

		ArrayDimensions pulseEchoDims;
		pulseEchoDims.push_back((uz)settings.sampleCount);
		pulseEchoDims.push_back((uz)receiveChannels.len);
		pulseEchoDims.push_back((uz)transmissions.len);
		outputs[0] = factory.createArrayFromBuffer(pulseEchoDims,
												   std::move(pulseEchoBuffer));

		switch (simulatorType) {
		case SimulatorType::CPU:
			destroy_cpu_simulator_c(simulator, printLogger, throwAssertion, this);
			break;
		case SimulatorType::GPU:
			destroy_vulkan_simulator_c(simulator, printLogger, throwAssertion, this);
			break;
		case SimulatorType::Hybrid:
			destroy_hybrid_simulator_c(simulator, printLogger, throwAssertion, this);
			break;
		}

		freeRectangularElementSoaSlice(&elements);
		freeTransmissionSlice(&transmissions);
		freeReceiveChannelSlice(&receiveChannels);
		freeSignalResponseSlice(&impulses);
		freeSignalResponseSlice(&excitations);
		free(scatters.data);

		void mexUnlock();

		// mexApiGetProperty
	}

	void checkArguments(ArgumentList outputs, ArgumentList inputs) {
		// std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		// ArrayFactory factory;
		// if (inputs[0].getType() != ArrayType::OBJECT) {
		// 	matlabPtr->feval(u"error", 0,
		// 					std::vector<Array>({
		// factory.createScalar("Input must be double array") }));
		// }
	}


	void readSimulationInputs(
		const ObjectArray& mxSimulator,
		SimulationSettings& settings,
		SimulatorType& simulatorType,
		RectangularElementSoaSlice& elements,
		TransmissionSlice& transmissions,
		ReceiveChannelSlice& receiveChannels,
		ScatterSlice& scatters,
		SignalResponseSlice& impulses,
		SignalResponseSlice& excitations) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();

		const EnumArray mxSimulatorType =
			matlabPtr->getProperty(mxSimulator, u"SimulatorType");
		const ObjectArray mxCpuSettings =
			matlabPtr->getProperty(mxSimulator, u"CpuSettings");
		const ObjectArray mxGpuSettings =
			matlabPtr->getProperty(mxSimulator, u"GpuSettings");
		const ObjectArray mxHybridSettings =
			matlabPtr->getProperty(mxSimulator, u"HybridSettings");
		const TypedArray<f32> mxSamplingFrequency =
			matlabPtr->getProperty(mxSimulator, u"SamplingFrequency");
		const TypedArray<f32> mxSpeedOfSound =
			matlabPtr->getProperty(mxSimulator, u"SpeedOfSound");
		const TypedArray<f32> mxStartTime =
			matlabPtr->getProperty(mxSimulator, u"StartTime");
		const TypedArray<u32> mxSampleCount =
			matlabPtr->getProperty(mxSimulator, u"SampleCount");
		const Array mxCumulative = matlabPtr->getProperty(mxSimulator, u"Cumulative");
		const ObjectArray mxElementSet =
			matlabPtr->getProperty(mxSimulator, u"Elements");
		const ObjectArray mxTransmissions =
			matlabPtr->getProperty(mxSimulator, u"Transmissions");
		const ObjectArray mxReceiveChannels =
			matlabPtr->getProperty(mxSimulator, u"ReceiveChannels");
		const ObjectArray mxScatterSet =
			matlabPtr->getProperty(mxSimulator, u"Scatters");
		const CellArray mxImpulses =
			matlabPtr->getProperty(mxSimulator, u"Impulses");
		const CellArray mxExcitations =
			matlabPtr->getProperty(mxSimulator, u"Excitations");

		const std::string simulatorTypeName = static_cast<std::string>( mxSimulatorType[0] );
		if (simulatorTypeName == "CPU") {
			simulatorType = SimulatorType::CPU;
		}
		else if (simulatorTypeName == "GPU") {
			simulatorType = SimulatorType::GPU;
		}
		else if (simulatorTypeName == "Hybrid") {
			simulatorType = SimulatorType::Hybrid;
		}
		else {
			throw std::runtime_error("Unsupported simulator type");
		}
		settings.samplingFrequency = mxSamplingFrequency[0];
		settings.speedOfSound = mxSpeedOfSound[0];
		settings.startTime = mxStartTime[0];
		settings.sampleCount = mxSampleCount[0];
		settings.cumulative = mxCumulative[0] ? 1u : 0u;
		i32 scatterCount = (i32)matlabPtr->getProperty(mxScatterSet, "Count")[0];
		settings.cpuSettings.threadCount = (u32)matlabPtr->getProperty(mxCpuSettings, "ThreadCount")[0];
		const EnumArray mxGpuBackend = matlabPtr->getProperty(mxGpuSettings, u"Backend");
		const std::string gpuBackendName = static_cast<std::string>( mxGpuBackend[0] );
		if (gpuBackendName == "Vulkan") {
			settings.gpuSettings.backend = GpuBackend::Vulkan;
		}
		else {
			throw std::runtime_error("Unsupported GPU backend");
		}
		settings.gpuSettings.enableDriverDebugMessages =
			matlabPtr->getProperty(mxGpuSettings, "EnableDriverDebugMessages")[0] ? 1u : 0u;
		settings.hybridSettings.cpuScatterFraction =
			matlabPtr->getProperty(mxHybridSettings, "CpuScatterFraction")[0];

		elements = { nullptr, nullptr, nullptr, nullptr, nullptr, 0 };
		transmissions = { nullptr, 0 };
		receiveChannels = { nullptr, 0 };
		impulses = { nullptr, 0 };
		excitations = { nullptr, 0 };
		scatters.data = (Scatter*)malloc(sizeof(Scatter) * scatterCount);
		scatters.len = scatterCount;

		copyElements(mxElementSet, &elements);
		copyReceiveChannels(mxReceiveChannels, &receiveChannels);
		copyTransmissions(mxTransmissions, &transmissions);
		copyScatters(mxScatterSet, scatters.data, scatters.len);
		copySignalResponses(mxImpulses, &impulses);
		copySignalResponses(mxExcitations, &excitations);
	}

	void copyElements(const Array& matlabArray, RectangularElementSoaSlice* slice) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();

		Array mxCount = matlabPtr->getProperty(matlabArray, "Count");
		Array mxPositions = matlabPtr->getProperty(matlabArray, "Positions");
		Array mxNormals = matlabPtr->getProperty(matlabArray, "Normals");
		Array mxSizes = matlabPtr->getProperty(matlabArray, "Sizes");
		Array mxApodizations = matlabPtr->getProperty(matlabArray, "Apodizations");
		Array mxDelays = matlabPtr->getProperty(matlabArray, "Delays");

		const uz count = static_cast<uz>( mxCount[0] );
		uz numelPositions = std::min(mxPositions.getNumberOfElements(), 3 * count);
		uz numelNormals = std::min(mxNormals.getNumberOfElements(), 3 * count);
		uz numelSizes = std::min(mxSizes.getNumberOfElements(), 2 * count);
		uz numelApodizations = std::min(mxApodizations.getNumberOfElements(), 1 * count);
		uz numelDelays = std::min(mxDelays.getNumberOfElements(), 1 * count);

		const f32* pPositions = getDataPtr<f32>(mxPositions);
		const f32* pNormals = getDataPtr<f32>(mxNormals);
		const f32* pSizes = getDataPtr<f32>(mxSizes);
		const f32* pApodizations = getDataPtr<f32>(mxApodizations);
		const f32* pDelays = getDataPtr<f32>(mxDelays);

		slice->position = new f32[numelPositions];
		slice->normal = new f32[numelNormals];
		slice->size = new f32[numelSizes];
		slice->apodization = new f32[numelApodizations];
		slice->delay = new f32[numelDelays];
		slice->len = static_cast<int>( mxCount[0] );

		std::memcpy(slice->position, pPositions, numelPositions * sizeof(f32));
		std::memcpy(slice->normal, pNormals, numelNormals * sizeof(f32));
		std::memcpy(slice->size, pSizes, numelSizes * sizeof(f32));
		std::memcpy(slice->apodization, pApodizations, numelApodizations * sizeof(f32));
		std::memcpy(slice->delay, pDelays, numelDelays * sizeof(f32));
	}

	void copyTransmissions(const ObjectArray& mxTransmissionSet, TransmissionSlice* slice) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		const TypedArray<u32> mxCount = matlabPtr->getProperty(mxTransmissionSet, u"Count");
		const TypedArray<u32> mxElementCounts = matlabPtr->getProperty(mxTransmissionSet, u"ElementCounts");
		const TypedArray<i32> mxIndices = matlabPtr->getProperty(mxTransmissionSet, u"Indices");
		const TypedArray<f32> mxApodizations = matlabPtr->getProperty(mxTransmissionSet, u"Apodizations");
		const TypedArray<f32> mxDelays = matlabPtr->getProperty(mxTransmissionSet, u"Delays");
		const TypedArray<u16> mxImpulses = matlabPtr->getProperty(mxTransmissionSet, u"Impulse");

		slice->len = static_cast<iz>( mxCount[0] );
		slice->data = new Transmission[slice->len];

		const uz totalElementCount = std::min({
			mxIndices.getNumberOfElements(),
			mxApodizations.getNumberOfElements(),
			mxDelays.getNumberOfElements(),
		});
		const u32* pElementCounts = getDataPtr<u32>(mxElementCounts);
		const i32* pIndices = getDataPtr<i32>(mxIndices);
		const f32* pApodizations = getDataPtr<f32>(mxApodizations);
		const f32* pDelays = getDataPtr<f32>(mxDelays);
		const u16* pImpulses = getDataPtr<u16>(mxImpulses);
		const TypedArray<u16> mxExcitations = matlabPtr->getProperty(mxTransmissionSet, u"Excitation");
		const u16* pExcitations = getDataPtr<u16>(mxExcitations);
		uz offset = 0;
		for (iz i = 0; i < slice->len; ++i) {
			const uz count = static_cast<uz>(pElementCounts[i]);
			const uz available = offset < totalElementCount ? totalElementCount - offset : 0;
			const uz numel = std::min(count, available);

			slice->data[i].elements.len = static_cast<iz>(count);
			slice->data[i].elements.index = new i32[numel];
			slice->data[i].elements.apodization = new f32[numel];
			slice->data[i].elements.delay = new f32[numel];
			slice->data[i].impulse = pImpulses[i];
			slice->data[i].excitation = pExcitations[i];

			std::memcpy(slice->data[i].elements.index, pIndices + offset, numel * sizeof(i32));
			std::memcpy(slice->data[i].elements.apodization, pApodizations + offset, numel * sizeof(f32));
			std::memcpy(slice->data[i].elements.delay, pDelays + offset, numel * sizeof(f32));

			for (uz j = 0; j < numel; ++j) {
				slice->data[i].elements.index[j] -= 1;
			}

			offset += count;
		}
	}

	void copyReceiveChannels(const ObjectArray& matlabArray, ReceiveChannelSlice* slice) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();
		const TypedArray<u32> mxCount = matlabPtr->getProperty(matlabArray, u"Count");
		const TypedArray<u32> mxElementCounts = matlabPtr->getProperty(matlabArray, u"ElementCounts");
		const TypedArray<i32> mxIndices = matlabPtr->getProperty(matlabArray, u"Indices");
		const TypedArray<f32> mxApodizations = matlabPtr->getProperty(matlabArray, u"Apodizations");
		const TypedArray<f32> mxDelays = matlabPtr->getProperty(matlabArray, u"Delays");
		const TypedArray<u16> mxImpulses = matlabPtr->getProperty(matlabArray, u"Impulse");

		slice->len = static_cast<iz>( mxCount[0] );
		slice->data = new ReceiveChannel[slice->len];
		const uz totalElementCount = std::min({ mxIndices.getNumberOfElements(), mxApodizations.getNumberOfElements(), mxDelays.getNumberOfElements() });
		const u32* pElementCounts = getDataPtr<u32>(mxElementCounts);
		const i32* pIndices = getDataPtr<i32>(mxIndices);
		const f32* pApodizations = getDataPtr<f32>(mxApodizations);
		const f32* pDelays = getDataPtr<f32>(mxDelays);
		const u16* pImpulses = getDataPtr<u16>(mxImpulses);

		uz offset = 0;
		for (iz i = 0; i < slice->len; ++i) {
			const uz count = static_cast<uz>(pElementCounts[i]);
			const uz available = offset < totalElementCount ? totalElementCount - offset : 0;
			const uz numel = std::min(count, available);
			slice->data[i].elements.len = static_cast<iz>(count);
			slice->data[i].elements.index = new i32[numel];
			slice->data[i].elements.apodization = new f32[numel];
			slice->data[i].elements.delay = new f32[numel];
			slice->data[i].impulse = pImpulses[i];
			std::memcpy(slice->data[i].elements.index, pIndices + offset, numel * sizeof(i32));
			std::memcpy(slice->data[i].elements.apodization, pApodizations + offset, numel * sizeof(f32));
			std::memcpy(slice->data[i].elements.delay, pDelays + offset, numel * sizeof(f32));
			for (uz j = 0; j < numel; ++j) slice->data[i].elements.index[j] -= 1;
			offset += count;
		}
	}

	void copySignalResponses(const CellArray& matlabArray, SignalResponseSlice* slice) {
		slice->len = static_cast<iz>(matlabArray.getNumberOfElements());
		slice->data = new SignalResponse[slice->len] { };
		for (iz i = 0; i < slice->len; ++i) {
			const Array response = matlabArray[i];
			const uz length = response.getNumberOfElements();
			slice->data[i].len = static_cast<iz>(length);
			slice->data[i].data = new f32[length];
			if (length != 0) {
				const f32* data = getDataPtr<f32>(response);
				std::memcpy(slice->data[i].data, data, length * sizeof(f32));
			}
		}
	}

	void copyScatters(const Array& matlabArray, Scatter* array, uz length) {
		std::shared_ptr<matlab::engine::MATLABEngine> matlabPtr = getEngine();

		constexpr uz countPositions = 3;
		constexpr uz countAmplitudes = 1;
		Array propertyPositions = matlabPtr->getProperty(matlabArray, "Positions");
		Array propertyAmplitudes =
			matlabPtr->getProperty(matlabArray, "Amplitudes");
		uz numelPositions = propertyPositions.getNumberOfElements();
		uz numelAmplitudes = propertyAmplitudes.getNumberOfElements();
		const f32* pPositions = getDataPtr<f32>(propertyPositions);
		const f32* pAmplitudes = getDataPtr<f32>(propertyAmplitudes);
		uz offsetPositions = 0;
		uz offsetAmplitudes = 0;
		for (uz i = 0; i < length; i++) {
			memcpy(&array[i].position, pPositions + offsetPositions,
				   countPositions * sizeof(f32));
			array[i].amplitude = *( pAmplitudes + offsetAmplitudes );
			offsetPositions =
				std::min(offsetPositions + countPositions, numelPositions);
			offsetAmplitudes =
				std::min(offsetAmplitudes + countAmplitudes, numelAmplitudes);
		}
	}
};
