scriptDirectory = fileparts(mfilename("fullpath"));
repoDirectory = fileparts(scriptDirectory);
addpath(repoDirectory);
addpath(scriptDirectory);
addpath(fullfile(repoDirectory, "matlab"));
addpath(fullfile(repoDirectory, "extern", "ornot", "matlab"));
ornot.LoadLibraries();

plotting = true;
plotGeometry = false;
combinePlots = true;

fs = single(50e6);
c = single(1540);
fc = single(5e6);
cycleCount = 2;
transmitFNumber = single(1);

rowCount = 128;
columnCount = 128;
elementWidth = single([2.2e-4, 2.2e-4]);
elementKerf = single([3e-5, 3e-5]);

[scatterX, scatterZ] = meshgrid(1e-3*(-10:5:10), linspace(20e-3, 100e-3, 20));
scatterCount = numel(scatterX);
scatterPosition = [
    scatterX(:).';
    zeros(1, scatterCount);
    scatterZ(:).'
    ];
scatterAmplitude = ones(scatterCount, 1, 'single');

array = tobe.RowColumnArray();
array.ElementCount = uint16([rowCount, columnCount]);
array.Pitch = elementWidth + elementKerf;
array.Kerf = elementKerf;
array.CenterFrequency = fc;

transmitOrientation = ZBP.RCAOrientation.Rows;
receiveOrientation = ZBP.RCAOrientation.Columns;
transmitFocus = ZBP.RCATransmitFocus();
transmitFocus.focal_depth = single(50e-3);
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

%% Field II Simulation
fieldII.field_init(-1);
fieldII.set_field('c', double(c));
fieldII.set_field('fs', double(fs));

tTh = createFieldIILinearArray(array, receiveOrientation);
receiveLineCount = double(array.ElementCount(int32(receiveOrientation)));
rTh = createFieldIILinearArray(array, receiveOrientation);
fieldII.xdc_impulse(tTh, double(impulseResponse));
fieldII.xdc_impulse(rTh, double(impulseResponse));
fieldII.xdc_excitation(tTh, double(excitation));
fieldIIRf = cell(transmitCount, 1);
fieldIIStartTime = zeros(transmitCount, 1);
fieldIIEndTime = zeros(transmitCount, 1);
fieldIITimer = tic();
for eventIndex = 1:transmitCount
    [isActive, fieldIIScatterPosition] = updateFieldIILinearArray(tTh, rTh, array, biasPattern(eventIndex, :), ...
        transmitApodization(eventIndex, :), transmitDelays(eventIndex, :), ...
        receiveApodization(eventIndex, :), receiveOrientation, scatterPosition);
    if isActive
        [fieldIIRf{eventIndex}, fieldIIStartTime(eventIndex)] = ...
            fieldII.calc_scat_multi(tTh, rTh, fieldIIScatterPosition', double(scatterAmplitude));
        fieldIIEndTime(eventIndex) = fieldIIStartTime(eventIndex) ...
            + size(fieldIIRf{eventIndex}, 1) / double(fs);
    end
end
templateEvent = find(~cellfun(@isempty, fieldIIRf), 1);
assert(~isempty(templateEvent), "FORCES sequence contains no active transmit events");
for eventIndex = 1:transmitCount
    if isempty(fieldIIRf{eventIndex})
        fieldIIRf{eventIndex} = zeros(size(fieldIIRf{templateEvent}), 'like', fieldIIRf{templateEvent});
        fieldIIStartTime(eventIndex) = fieldIIStartTime(templateEvent);
        fieldIIEndTime(eventIndex) = fieldIIEndTime(templateEvent);
    end
end
[fieldIIRf, fieldIIStartTime, fieldIIEndTime] = ...
    padEventData(fieldIIRf, fieldIIStartTime, fieldIIEndTime, fs);
fieldIIRf = cat(3, fieldIIRf{:});
fieldIITime = toc(fieldIITimer);

%% Ekhos Simulation
simulator = ekhos.Simulation();
simulator.Cumulative = false;
simulator.SimulatorType = ekhos.SimulatorType.CPU;
simulator.SamplingFrequency = fs;
simulator.SpeedOfSound = c;
simulator.Impulses = {single(impulseResponse)};
simulator.Excitations = {single(excitation)};
fieldIITransmitElements = fieldIIArrayToEkhosArray(tTh);
fieldIIReceiveElements = fieldIIArrayToEkhosArray(rTh);
[sequenceElements, sequenceTransmissions, sequenceReceiveChannels] = ...
    sequenceToElementSets(array, biasPattern, transmitApodization, transmitDelays, receiveApodization);
simulator.Elements = sequenceElements;
if plotting && plotGeometry
    plot_element_geometry(fieldIITransmitElements, fieldIIReceiveElements, ...
        sequenceElements.Positions, sequenceElements.Sizes, ...
        sequenceElements.Positions, sequenceElements.Sizes, ...
        'FORCES physical elements');
end
simulator.Scatters = ekhos.ScatterSet();
simulator.Scatters.Count = uint32(scatterCount);
simulator.Scatters.Positions = single(scatterPosition);
simulator.Scatters.Amplitudes = scatterAmplitude;

vkTimer = tic();
vkPulseEcho = cell(transmitCount, 1);
vkStartTime = zeros(transmitCount, 1);
vkEndTime = zeros(transmitCount, 1);
for eventIndex = 1:transmitCount
    simulator.Transmissions = sequenceTransmissions(eventIndex);
    receive = sequenceReceiveChannels(eventIndex);
    simulator.ReceiveChannels = receive;
    vkPulseEcho{eventIndex} = simulator.call();
    vkStartTime(eventIndex) = simulator.StartTime;
    vkEndTime(eventIndex) = vkStartTime(eventIndex) ...
        + size(vkPulseEcho{eventIndex}, 1) / double(fs);
end
if all(cellfun(@isempty, vkPulseEcho))
    error("FORCES sequence contains no active transmit events");
end
[vkPulseEcho, vkStartTime, vkEndTime] = padEventData(vkPulseEcho, vkStartTime, vkEndTime, fs);
vkPulseEcho = cat(3, vkPulseEcho{:});
vkTime = toc(vkTimer);

fprintf("Field II samples == %d, Ekhos samples == %d\n", size(fieldIIRf, 1), size(vkPulseEcho, 1));
fprintf("Field II start time == %.9g, Ekhos start time == %.9g\n", ...
    min(fieldIIStartTime), simulator.StartTime);
fprintf("Field II simulation time == %.6f s\n", fieldIITime);
fprintf("Ekhos simulation time == %.6f s\n", vkTime);
fprintf("Simulation speed-up == %.3fx\n", fieldIITime / vkTime);

fieldIIData = stackEventData(fieldIIRf);
vkData = stackEventData(vkPulseEcho);
fieldIITimes = min(fieldIIStartTime) + (0:size(fieldIIData, 1) - 1) / double(fs);
vkTimes = min(vkStartTime) + (0:size(vkData, 1) - 1) / double(fs);
[responseMetrics, ~, ~, ~] = signal_metrics_aligned( ...
    vkData, vkTimes, fieldIIData, fieldIITimes, fs);
fprintf("Field II/Ekhos response correlation == %.6f (RMS error == %.2f%%, peak ratio == %.6f)\n", ...
    responseMetrics.correlation, responseMetrics.rmsErrorPercent, responseMetrics.peakRatio);

fieldIIBp = bp;
fieldIIBp.raw_data_dimension = uint32([size(fieldIIData, 1), receiveLineCount, 1, 1]);
fieldIIBp.raw_data_kind = ZBP.DataKind.Float32;
fieldIIBp.raw_data_compression_kind = ZBP.DataCompressionKind.None;
fieldIIBp.decode_mode = ZBP.DecodeMode.Hadamard;
fieldIIBp.sampling_mode = ZBP.SamplingMode.Standard;
fieldIIBp.sampling_frequency = fs;
fieldIIBp.demodulation_frequency = fc;
fieldIIBp.sample_count = uint32(size(fieldIIRf, 1));
fieldIIBp.channel_count = uint32(receiveLineCount);
fieldIIBp.receive_event_count = uint32(transmitCount);
fieldIIBp.time_offset = single(bp.time_offset - min(fieldIIStartTime));
fieldIIBp.data = single(fieldIIData * 1e30);

vkBp = bp;
vkBp.raw_data_dimension = uint32([size(vkData, 1), receiveLineCount, 1, 1]);
vkBp.raw_data_kind = ZBP.DataKind.Float32;
vkBp.raw_data_compression_kind = ZBP.DataCompressionKind.None;
vkBp.decode_mode = ZBP.DecodeMode.Hadamard;
vkBp.sampling_mode = ZBP.SamplingMode.Standard;
vkBp.sampling_frequency = fs;
vkBp.demodulation_frequency = fc;
vkBp.sample_count = uint32(size(vkPulseEcho, 1));
vkBp.channel_count = uint32(receiveLineCount);
vkBp.receive_event_count = uint32(transmitCount);
vkBp.time_offset = single(bp.time_offset - simulator.StartTime);
vkBp.data = single(vkData * (1 / double(fs)) * 1e30);

beamformSettings = ornot.BeamformSettings();
xRange = [-15, 15] * 1e-3;
zRange = [15, 105] * 1e-3;
resolution = [512, 1024];
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

fieldIIBeamformTimer = tic();
fieldIIImage = ornot.beamform(fieldIIBp, beamformSettings);
fieldIIBeamformTime = toc(fieldIIBeamformTimer);
vkBeamformTimer = tic();
vkImage = ornot.beamform(vkBp, beamformSettings);
vkBeamformTime = toc(vkBeamformTimer);

fprintf("Field II beamform time == %.6f s\n", fieldIIBeamformTime);
fprintf("Ekhos beamform time == %.6f s\n", vkBeamformTime);

if plotting
    imageX = linspace(xRange(1), xRange(2), size(fieldIIImage{1}, 1));
    imageZ = linspace(zRange(1), zRange(2), size(fieldIIImage{1}, 2));
    fieldIIImageDb = 20*log10(abs(fieldIIImage{1}) / max(abs(fieldIIImage{1}), [], 'all'));
    vkImageDb = 20*log10(abs(vkImage{1}) / max(abs(vkImage{1}), [], 'all'));
    if combinePlots
        figure('Name', 'FORCES - Field II and Ekhos', 'Position', [100, 100, 605, 650]);
        tiledLayout = tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
        fieldIIAxes = nexttile(tiledLayout);
        ekhosAxes = nexttile(tiledLayout);
    else
        fieldIIFigure = figure('Name', 'FORCES - Field II', 'Position', [100, 100, 605, 650]);
        fieldIIAxes = axes(fieldIIFigure);
        ekhosFigure = figure('Name', 'FORCES - Ekhos', 'Position', [800, 100, 605, 650]);
        ekhosAxes = axes(ekhosFigure);
    end

    axes(fieldIIAxes);
    colormap(gray);
    imagesc(imageX * 1e3, imageZ * 1e3, fieldIIImageDb');
    axis image;
    clim([-40, 0]);
    title("Field II");
    xlabel("x (mm), dB");
    ylabel("z (mm)");
    colorbar('westoutside');

    axes(ekhosAxes);
    colormap(gray);
    imagesc(imageX * 1e3, imageZ * 1e3, vkImageDb');
    axis image;
    clim([-40, 0]);
    title("Ekhos");
    xlabel("x (mm), dB");
    set(gca, 'YColor', 'none');
    colorbar;
    saveas(gcf, fullfile(repoDirectory, "figures", "forcesComparison.png"));
end

function data = stackEventData(eventData)
arguments
    eventData(:, :, :)
end
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



