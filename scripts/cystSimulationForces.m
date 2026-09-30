scriptDirectory = fileparts(mfilename("fullpath"));
repoDirectory = fileparts(scriptDirectory);
addpath(repoDirectory);
addpath(scriptDirectory);
addpath(fullfile(repoDirectory, "matlab"));
addpath(fullfile(repoDirectory, "extern", "ornot", "matlab"));
ornot.LoadLibraries();

plotting = true;

fs = single(100e6);
c = single(1540);
fc = single(5e6);
cycleCount = 2;
transmitFNumber = single(1);

rowCount = 128;
columnCount = 128;
elementWidth = single([2.2e-4, 2.2e-4]);
elementKerf = single([3e-5, 3e-5]);

array = tobe.RowColumnArray();
array.ElementCount = uint16([rowCount, columnCount]);
array.Pitch = elementWidth + elementKerf;
array.Kerf = elementKerf;
array.CenterFrequency = fc;

focalDepth = single(rowCount) * array.Pitch(1);
cystRadii = single([0.75e-3, 1.5e-3, 2.25e-3]);
cystCentersX = single([-7e-3, 0, 7e-3]);
cystAmplitudeScale = single(0.1);

randomStream = RandStream("mt19937ar", "Seed", 1);
backgroundCount = 30000;
scatterX = single((2 * rand(randomStream, 1, backgroundCount) - 1) * 18e-3);
scatterZ = single(15e-3 + rand(randomStream, 1, backgroundCount) * 34e-3);
scatterY = zeros(1, backgroundCount, 'single');
insideCyst = false(1, backgroundCount);
for cystIndex = 1:numel(cystRadii)
	insideCyst = insideCyst | ...
		(scatterX - cystCentersX(cystIndex)).^2 ...
		+ (scatterZ - focalDepth).^2 < cystRadii(cystIndex).^2;
end
scatterPosition = [scatterX; scatterY; scatterZ];
scatterCount = size(scatterPosition, 2);
scatterAmplitude = single(2 * rand(randomStream, 1, scatterCount) - 1);
scatterAmplitude(insideCyst) = scatterAmplitude(insideCyst) * cystAmplitudeScale;

transmitOrientation = ZBP.RCAOrientation.Rows;
receiveOrientation = ZBP.RCAOrientation.Columns;
transmitFocus = ZBP.RCATransmitFocus();
transmitFocus.focal_depth = focalDepth;
transmitFocus.origin_offset = single(0);
transmitFocus.transmit_receive_orientation = ...
	ornot.packTransmitReceiveOrientation(transmitOrientation, receiveOrientation);
forcesParameters = ZBP.FORCESParameters();
forcesParameters.transmit_focus = transmitFocus;

[biasPattern, transmitApodization, transmitDelays, receiveApodization, bp] ...
	= tobe.createForcesSequence(array, forcesParameters, c, transmitFNumber);
emissionParameters = ZBP.EmissionSineParameters();
emissionParameters.cycles = cycleCount;
emissionParameters.frequency = fc;
bp.emission_descriptors = uint8(1);
bp.emission_parameters = {emissionParameters};
transmitCount = size(biasPattern, 1);

impulseResponse = GetImpulseResponse(fc, fs);
excitation = sin(2*pi*(0:1/double(fs):cycleCount/double(fc))*double(fc));

simulator = ekhos.Simulation();
simulator.Cumulative = false;
simulator.SimulatorType = ekhos.SimulatorType.GPU;
simulator.GpuSettings.Backend = ekhos.GpuBackend.Vulkan;
simulator.SamplingFrequency = fs;
simulator.SpeedOfSound = c;
simulator.Impulses = {single(impulseResponse)};
simulator.Excitations = {single(excitation)};
[sequenceElements, sequenceTransmissions, sequenceReceiveChannels] = ...
	sequenceToElementSets(array, biasPattern, transmitApodization, transmitDelays, receiveApodization);
simulator.Elements = sequenceElements;
simulator.Scatters = ekhos.ScatterSet();
simulator.Scatters.Count = uint32(scatterCount);
simulator.Scatters.Positions = single(scatterPosition);
simulator.Scatters.Amplitudes = scatterAmplitude;

gpuPulseEcho = cell(transmitCount, 1);
gpuStartTime = zeros(transmitCount, 1);
gpuEndTime = zeros(transmitCount, 1);
gpuTimer = tic();
for eventIndex = 1:transmitCount
	simulator.Transmissions = sequenceTransmissions(eventIndex);
	simulator.ReceiveChannels = sequenceReceiveChannels(eventIndex);
	gpuPulseEcho{eventIndex} = simulator.call();
	gpuStartTime(eventIndex) = simulator.StartTime;
	gpuEndTime(eventIndex) = gpuStartTime(eventIndex) ...
		+ size(gpuPulseEcho{eventIndex}, 1) / double(fs);
end
if all(cellfun(@isempty, gpuPulseEcho))
	error("FORCES sequence contains no active transmit events");
end
[gpuPulseEcho, gpuStartTime, gpuEndTime] = padEventData(gpuPulseEcho, gpuStartTime, gpuEndTime, fs);
gpuData = stackEventData(cat(3, gpuPulseEcho{:}));
fprintf("GPU Ekhos simulation time == %.6f s\n", toc(gpuTimer));

bp.raw_data_dimension = uint32([size(gpuData, 1), columnCount, 1, 1]);
bp.raw_data_kind = ZBP.DataKind.Float32;
bp.raw_data_compression_kind = ZBP.DataCompressionKind.None;
bp.decode_mode = ZBP.DecodeMode.Hadamard;
bp.sampling_mode = ZBP.SamplingMode.Standard;
bp.sampling_frequency = fs;
bp.demodulation_frequency = fc;
bp.sample_count = uint32(size(gpuData, 1));
bp.channel_count = uint32(columnCount);
bp.receive_event_count = uint32(transmitCount);
bp.time_offset = single(bp.time_offset - min(gpuStartTime));
bp.data = single(gpuData * (1 / double(fs)) * 1e30);

beamformSettings = ornot.BeamformSettings();
xRange = [-18, 18] * 1e-3;
zRange = [15, 49] * 1e-3;
resolution = [512, 768];
beamformSettings.regions = ornot.Region.CreateXZPlane(resolution, xRange, zRange);
beamformSettings.interpolation_mode = OGLBeamformerInterpolationMode.Cubic;
beamformSettings.receive_fnumber = 0;
beamformSettings.coherency_weighting = false;
beamformSettings.decimation_rate = 1;
beamformSettings.compute_stages = [
	OGLBeamformerShaderStage.Demodulate, ...
	OGLBeamformerShaderStage.Decode, ...
	OGLBeamformerShaderStage.DAS
	];

gpuImage = ornot.beamform(bp, beamformSettings);
if plotting
	imageX = linspace(xRange(1), xRange(2), size(gpuImage{1}, 1));
	imageZ = linspace(zRange(1), zRange(2), size(gpuImage{1}, 2));
	imageDb = 20 * log10(abs(gpuImage{1}) / max(abs(gpuImage{1}), [], 'all'));
	figure('Name', 'FORCES - GPU Ekhos anechoic cysts');
	imagesc(imageX * 1e3, imageZ * 1e3, imageDb');
	axis image;
	clim([-45, 0]);
	colormap(gray);
	xlabel('x (mm)');
	ylabel('z (mm)');
	title(sprintf('GPU Ekhos FORCES, f-number %.1f, focus %.1f mm', ...
		transmitFNumber, focalDepth * 1e3));
	colorbar;
end

function data = stackEventData(eventData)
sampleCount = size(eventData, 1);
receiveChannelCount = size(eventData, 2);
eventCount = size(eventData, 3);
data = reshape(permute(eventData, [1, 3, 2]), ...
	sampleCount * eventCount, receiveChannelCount);
end

function [data, startTimes, endTimes] = padEventData(data, startTimes, endTimes, samplingFrequency)
minStartTime = min(startTimes);
for eventIndex = 1:numel(data)
	prePadSize = floor((startTimes(eventIndex) - minStartTime) * double(samplingFrequency) + 0.01);
	data{eventIndex} = padarray(data{eventIndex}, double(prePadSize), 0, 'pre');
end
maxEndTime = max(endTimes);
for eventIndex = 1:numel(data)
	endTime = minStartTime + size(data{eventIndex}, 1) / double(samplingFrequency);
	postPadSize = ceil((maxEndTime - endTime) * double(samplingFrequency) + 0.01);
	data{eventIndex} = padarray(data{eventIndex}, double(postPadSize), 0, 'post');
end
end
