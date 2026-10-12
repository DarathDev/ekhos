%% Compare one tilted transmit/receive rectangle against Field II
scriptDirectory = fileparts(mfilename('fullpath'));
repositoryDirectory = fileparts(scriptDirectory);
addpath(repositoryDirectory);
addpath(scriptDirectory);
addpath(fullfile(repositoryDirectory, 'matlab'));
addpath(fullfile(repositoryDirectory, 'scripts', 'color'));

fs = 100e6;
c = 1540;
fc = 5e6;
cycleCount = 2;
dt = 1 / fs;
impulseResponse = GetImpulseResponse(single(fc), single(fs));
excitation = sin(2 * pi * (0:dt:cycleCount / fc) * fc);
rawImpulseResponse = 1;
rawExcitation = 1;
% impulseResponse = 1;
% excitation = 1;
rectangleSize = [2.2e-4; 2.2e-4];
caseCount = 32;
plotting = true;
plotHighErrorCases = false;
plotCorrelationThreshold = 0.99;
originApertures = true;
geometryTolerance = 1e-9;
angleTolerance = 1e-6;

scatterRangeMin = [-10e-3; -10e-3; 10e-3];
scatterRangeMax = [10e-3; 10e-3; 30e-3];

% Fixed seed makes every reported case reproducible.
rng(1, 'twister');

fieldII.field_init(-1);
fieldII.set_field('c', c);
fieldII.set_field('fs', fs);

results = repmat(struct( ...
    'caseIndex', 0, ...
    'scatterPosition', zeros(3, 1), ...
    'transmitPosition', zeros(3, 1), ...
    'receivePosition', zeros(3, 1), ...
    'transmitOrientation', zeros(4, 1), ...
    'receiveOrientation', zeros(4, 1), ...
    'fieldCpuRmsErrorPercent', 0, ...
    'rawFieldCpuRmsErrorPercent', 0, ...
    'compareTimes', [], ...
    'fieldAligned', [], ...
    'cpuAligned', [], ...
    'gpuAligned', [], ...
    'rawCompareTimes', [], ...
    'rawFieldAligned', [], ...
    'rawCpuAligned', [], ...
    'rawGpuAligned', []), 1, caseCount);

for caseIndex = 1:caseCount
    scatterPosition = random_position(scatterRangeMin, scatterRangeMax);
    if originApertures
        transmitPosition = [0; 0; 0];
        receivePosition = [0; 0; 0];
        transmitOrientation = [0; 0; 0; 1];
        receiveOrientation = [0; 0; 0; 1];
    else
        transmitPosition = random_position([-5e-3; -5e-3; -2e-3], [5e-3; 5e-3; 2e-3]);
        receivePosition = random_position([-5e-3; -5e-3; -2e-3], [5e-3; 5e-3; 2e-3]);
        transmitOrientation = randomQuaternion();
        receiveOrientation = randomQuaternion();
    end
    transmitFrame = quaternionToFrame(transmitOrientation);
    receiveFrame = quaternionToFrame(receiveOrientation);

    fprintf(['case=%d scatter=[%.3f %.3f %.3f] mm tx=[%.4g %.4g %.4g] ', ...
        'rx=[%.4g %.4g %.4g] txQuat=[%.4g %.4g %.4g %.4g] ', ...
        'rxQuat=[%.4g %.4g %.4g %.4g]\n'], caseIndex, scatterPosition * 1e3, ...
        transmitPosition, receivePosition, transmitOrientation, receiveOrientation);

    if originApertures
        transmitAperture = fieldII.xdc_2d_array(1, 1, rectangleSize(1), rectangleSize(2), 3e-5, 3e-5, 1, 1, 1, [0, 0, 1e10]);
        receiveAperture = fieldII.xdc_2d_array(1, 1, rectangleSize(1), rectangleSize(2), 3e-5, 3e-5, 1, 1, 1, [0, 0, 1e10]);
    else
        transmitAperture = make_field_ii_rectangle(transmitPosition, transmitFrame, rectangleSize);
        receiveAperture = make_field_ii_rectangle(receivePosition, receiveFrame, rectangleSize);
    end
    transmitRectData = fieldII.xdc_get(transmitAperture, 'rect');
    receiveRectData = fieldII.xdc_get(receiveAperture, 'rect');
    if originApertures
        validate_fieldii_axis(transmitRectData, transmitPosition, transmitFrame, angleTolerance);
        validate_fieldii_axis(receiveRectData, receivePosition, receiveFrame, angleTolerance);
    else
        validate_fieldii_rectangle(transmitRectData, transmitPosition, transmitFrame, rectangleSize, geometryTolerance, angleTolerance);
        validate_fieldii_rectangle(receiveRectData, receivePosition, receiveFrame, rectangleSize, geometryTolerance, angleTolerance);
    end
    fieldII.xdc_impulse(transmitAperture, 1);
    fieldII.xdc_impulse(receiveAperture, 1);
    fieldII.xdc_excitation(transmitAperture, 1);
    fieldII.xdc_apodization(transmitAperture, 0, 1);
    fieldII.xdc_apodization(receiveAperture, 0, 1);
    [fieldData, fieldStartTime] = fieldII.calc_scat_multi(transmitAperture, receiveAperture, scatterPosition', 1);
    rawFieldData = double(fieldData) / dt;
    fieldData = applyResponseFilters(double(fieldData) / dt^4, impulseResponse, excitation, dt);
    fieldTimes = fieldStartTime + (0:size(fieldData, 1) - 1) / fs;

    elementPositions = single([transmitPosition, receivePosition]);
    elementOrientations = single([transmitOrientation, receiveOrientation]);
    elementSizes = single(repmat(rectangleSize, 1, 2));
    elementApodizations = single([1, 1]);
    elementDelays = single([0, 0]);

    [cpuData, cpuStartTime] = run_ekhos(ekhos.SimulatorType.CPU, elementPositions, elementOrientations, elementSizes, ...
        elementApodizations, elementDelays, scatterPosition, fs, c, impulseResponse, excitation);
    [gpuData, gpuStartTime] = run_ekhos(ekhos.SimulatorType.GPU, elementPositions, elementOrientations, elementSizes, ...
        elementApodizations, elementDelays, scatterPosition, fs, c, impulseResponse, excitation);
    [rawCpuData, rawCpuStartTime] = run_ekhos(ekhos.SimulatorType.CPU, elementPositions, elementOrientations, elementSizes, ...
        elementApodizations, elementDelays, scatterPosition, fs, c, rawImpulseResponse, rawExcitation);
    [rawGpuData, rawGpuStartTime] = run_ekhos(ekhos.SimulatorType.GPU, elementPositions, elementOrientations, elementSizes, ...
        elementApodizations, elementDelays, scatterPosition, fs, c, rawImpulseResponse, rawExcitation);

    [fieldAligned, cpuAligned, gpuAligned, compareTimes] = align_signals(...
        cpuData, cpuStartTime, gpuData, gpuStartTime, fieldData, fieldStartTime, fs);
    [rawFieldAligned, rawCpuAligned, rawGpuAligned, rawCompareTimes] = align_signals(...
        rawCpuData, rawCpuStartTime, rawGpuData, rawGpuStartTime, rawFieldData, fieldStartTime, fs);
    difference = cpuAligned - gpuAligned;
    cpuGpuMetrics = signal_metrics(cpuAligned, gpuAligned);
    fieldCpuDifference = cpuAligned - fieldAligned;
    fieldGpuDifference = gpuAligned - fieldAligned;
    fieldCpuMetrics = signal_metrics(cpuAligned, fieldAligned);
    fieldGpuMetrics = signal_metrics(gpuAligned, fieldAligned);
    rawFieldCpuMetrics = signal_metrics(rawCpuAligned, rawFieldAligned);

    results(caseIndex).caseIndex = caseIndex;
    results(caseIndex).scatterPosition = scatterPosition;
    results(caseIndex).transmitPosition = transmitPosition;
    results(caseIndex).receivePosition = receivePosition;
    results(caseIndex).transmitOrientation = transmitOrientation;
    results(caseIndex).receiveOrientation = receiveOrientation;
    results(caseIndex).cpuGpuMaxRelativeDifference = cpuGpuMetrics.maxRelativeDifference;
    results(caseIndex).fieldCpuRmsErrorPercent = fieldCpuMetrics.rmsErrorPercent;
    results(caseIndex).rawFieldCpuRmsErrorPercent = rawFieldCpuMetrics.rmsErrorPercent;
    results(caseIndex).compareTimes = compareTimes;
    results(caseIndex).fieldAligned = fieldAligned;
    results(caseIndex).cpuAligned = cpuAligned;
    results(caseIndex).gpuAligned = gpuAligned;
    results(caseIndex).rawCompareTimes = rawCompareTimes;
    results(caseIndex).rawFieldAligned = rawFieldAligned;
    results(caseIndex).rawCpuAligned = rawCpuAligned;
    results(caseIndex).rawGpuAligned = rawGpuAligned;
    fprintf(['  FieldII/CPU energyRatio=%.4g peakRatio=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%\n'], ...
        fieldCpuMetrics.differenceEnergyRatio, fieldCpuMetrics.peakRatio, fieldCpuMetrics.correlation, ...
        fieldCpuMetrics.maxRelativeDifference, fieldCpuMetrics.rmsErrorPercent);
    fprintf(['  FieldII/GPU energyRatio=%.4g peakRatio=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%\n'], ...
        fieldGpuMetrics.differenceEnergyRatio, fieldGpuMetrics.peakRatio, fieldGpuMetrics.correlation, ...
        fieldGpuMetrics.maxRelativeDifference, fieldGpuMetrics.rmsErrorPercent);
    fprintf(['  CPU/GPU energyRatio=%.4g peakRatio=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%\n'], ...
        cpuGpuMetrics.differenceEnergyRatio, cpuGpuMetrics.peakRatio, cpuGpuMetrics.correlation, ...
        cpuGpuMetrics.maxRelativeDifference, cpuGpuMetrics.rmsErrorPercent);

    if plotting && fieldCpuMetrics.correlation < plotCorrelationThreshold
        plot_case(compareTimes, fieldAligned, cpuAligned, gpuAligned, caseIndex, scatterPosition, ...
            transmitPosition, receivePosition, transmitOrientation, receiveOrientation);
    end

end

fprintf('Completed %d reproducible one-rectangle cases.\n', caseCount);
summaryFigure = figure('Name', 'Scatterer errors and best/worst cases', ...
    'Units', 'pixels', 'Position', [100, 100, 990, 633]);
summaryLayout = tiledlayout(summaryFigure, 4, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
plot_scatter_errors(summaryLayout, results, rectangleSize);
[~, bestCaseIndex] = min([results.rawFieldCpuRmsErrorPercent]);
[~, worstCaseIndex] = max([results.rawFieldCpuRmsErrorPercent]);
bestCaseAxes = nexttile(summaryLayout);
summaryPlotHandles = plot_case(results(bestCaseIndex).rawCompareTimes, results(bestCaseIndex).rawFieldAligned, ...
    results(bestCaseIndex).rawCpuAligned, results(bestCaseIndex).rawGpuAligned, ...
    results(bestCaseIndex).caseIndex, results(bestCaseIndex).scatterPosition, ...
    results(bestCaseIndex).transmitPosition, results(bestCaseIndex).receivePosition, ...
    results(bestCaseIndex).transmitOrientation, results(bestCaseIndex).receiveOrientation, ...
    bestCaseAxes, 'Best case');
worstCaseAxes = nexttile(summaryLayout);
plot_case(results(worstCaseIndex).rawCompareTimes, results(worstCaseIndex).rawFieldAligned, ...
    results(worstCaseIndex).rawCpuAligned, results(worstCaseIndex).rawGpuAligned, ...
    results(worstCaseIndex).caseIndex, results(worstCaseIndex).scatterPosition, ...
    results(worstCaseIndex).transmitPosition, results(worstCaseIndex).receivePosition, ...
    results(worstCaseIndex).transmitOrientation, results(worstCaseIndex).receiveOrientation, ...
    worstCaseAxes, 'Worst case');
worstCaseAxes.YAxisLocation = 'right';
plot_case(results(bestCaseIndex).compareTimes, results(bestCaseIndex).fieldAligned, ...
    results(bestCaseIndex).cpuAligned, results(bestCaseIndex).gpuAligned, ...
    results(bestCaseIndex).caseIndex, results(bestCaseIndex).scatterPosition, ...
    results(bestCaseIndex).transmitPosition, results(bestCaseIndex).receivePosition, ...
    results(bestCaseIndex).transmitOrientation, results(bestCaseIndex).receiveOrientation, ...
    nexttile(summaryLayout), 'Best case (Convolved with temporal response)');
convolvedWorstCaseAxes = nexttile(summaryLayout);
plot_case(results(worstCaseIndex).compareTimes, results(worstCaseIndex).fieldAligned, ...
    results(worstCaseIndex).cpuAligned, results(worstCaseIndex).gpuAligned, ...
    results(worstCaseIndex).caseIndex, results(worstCaseIndex).scatterPosition, ...
    results(worstCaseIndex).transmitPosition, results(worstCaseIndex).receivePosition, ...
    results(worstCaseIndex).transmitOrientation, results(worstCaseIndex).receiveOrientation, ...
    convolvedWorstCaseAxes, 'Worst case (Convolved with temporal response)');
convolvedWorstCaseAxes.YAxisLocation = 'right';
summaryLegend = legend(bestCaseAxes, summaryPlotHandles, {'Field II', 'Ekhos CPU', 'Ekhos GPU'}, ...
    'Location', 'southoutside', 'NumColumns', 3);
summaryLegend.Layout.Tile = 'south';
saveas(summaryFigure, fullfile('figures', 'randomizedFieldIIEkhosOneRect.png'));
saveas(summaryFigure, fullfile('figures', 'randomizedFieldIIEkhosOneRect.fig'));

function plot_scatter_errors(layout, results, rectangleSize)
scatterPositions = [results.scatterPosition] * 1e3;
rmsErrors = [results.fieldCpuRmsErrorPercent];
rectangleSize = rectangleSize * 1e3;

axesHandle = nexttile(layout, [2 2]);
axes(axesHandle);
hold on;
scatterHandle = scatter3(scatterPositions(1, :), scatterPositions(2, :), scatterPositions(3, :), ...
    64, rmsErrors, 'filled');
scatterHandle.MarkerFaceAlpha = 0.65;
scatterHandle.MarkerEdgeColor = 'flat';
scatterHandle.MarkerEdgeAlpha = 0.9;
scatterHandle.LineWidth = 0.75;
patch('Vertices', [-rectangleSize(1) / 2, -rectangleSize(2) / 2, 0; ...
    -rectangleSize(1) / 2,  rectangleSize(2) / 2, 0; ...
    rectangleSize(1) / 2,  rectangleSize(2) / 2, 0; ...
    rectangleSize(1) / 2, -rectangleSize(2) / 2, 0], ...
    'Faces', [1, 2, 3, 4], ...
    'FaceColor', [0.35, 0.35, 0.35], ...
    'FaceAlpha', 0.2, ...
    'EdgeColor', [0.15, 0.15, 0.15], ...
    'LineWidth', 1.5);
axis equal;
view(3);
grid on;
xlabel('Scatterer x (mm)');
ylabel('Scatterer y (mm)');
zlabel('Scatterer z (mm)');
title('Field II/CPU RMS error by scatterer position');
colormap(colorcet('L08', 'N', 256));
colorbarHandle = colorbar;
ylabel(colorbarHandle, 'RMS error (%)');
end

function [data, startTime] = run_ekhos(simulatorType, positions, orientations, sizes, apodizations, delays, scatterPosition, fs, c, impulseResponse, excitation)
simulation = ekhos.Simulation();
simulation.SimulatorType = simulatorType;
simulation.Cumulative = true;
simulation.GpuSettings.EnableDriverDebugMessages = false;
simulation.SamplingFrequency = single(fs);
simulation.SpeedOfSound = single(c);
simulation.Impulses = {single(impulseResponse)};
simulation.Excitations = {single(excitation)};
simulation.Elements = ekhos.RectangularElementSet();
simulation.Elements.Count = uint32(2);
simulation.Elements.Positions = positions;
simulation.Elements.Orientations = orientations;
simulation.Elements.Sizes = sizes;
simulation.Elements.Apodizations = apodizations;
simulation.Elements.Delays = delays;
transmission = ekhos.TransmissionSet();
transmission.Count = uint32(1);
transmission.ElementCounts = uint32(1);
transmission.Indices = int32(1);
transmission.Apodizations = single(1);
transmission.Delays = single(0);
transmission.Impulse = ones(1, transmission.Count, 'uint16');
transmission.Excitation = ones(1, transmission.Count, 'uint16');
simulation.Transmissions = transmission;
receiveChannel = ekhos.ReceiveChannelSet();
receiveChannel.Count = uint32(1);
receiveChannel.ElementCounts = uint32(1);
receiveChannel.Indices = int32(2);
receiveChannel.Apodizations = single(1);
receiveChannel.Delays = single(0);
receiveChannel.Impulse = ones(1, receiveChannel.Count, 'uint16');
simulation.ReceiveChannels = receiveChannel;
simulation.Scatters = ekhos.ScatterSet();
simulation.Scatters.Count = uint32(1);
simulation.Scatters.Positions = single(scatterPosition);
simulation.Scatters.Amplitudes = single(1);
data = squeeze(double(simulation.call()));
simulatorLabel = 'CPU';
if simulatorType == ekhos.SimulatorType.GPU
    simulatorLabel = 'GPU';
end
fprintf('raw %s peak=%e\n', simulatorLabel, max(abs(data), [], 'all'));
startTime = double(simulation.StartTime);
end

function rectangle = make_field_ii_rectangle(position, frame, size)
halfWidth = size(1) / 2;
halfHeight = size(2) / 2;
u = frame(:, 1) * halfWidth;
v = frame(:, 2) * halfHeight;
corners = [position - u - v, position - u + v, position + u + v, position + u - v];
rectangle = [1, reshape(corners', 1, []), 1, size(1), size(2), position'];
rectangle = fieldII.xdc_rectangles(rectangle, position', [0, 0, 1e10]);
end

function quaternion = randomQuaternion()
uniformValues = rand(3, 1);
quaternion = [sqrt(1 - uniformValues(1)) * sin(2 * pi * uniformValues(2));
              sqrt(1 - uniformValues(1)) * cos(2 * pi * uniformValues(2));
              sqrt(uniformValues(1)) * sin(2 * pi * uniformValues(3));
              sqrt(uniformValues(1)) * cos(2 * pi * uniformValues(3))];
end

function frame = quaternionToFrame(quaternion)
axis = quaternion(1:3);
w = quaternion(4);
frame = [rotateVector([1; 0; 0]), rotateVector([0; 1; 0]), rotateVector([0; 0; 1])];

    function rotated = rotateVector(vector)
        t = 2 * cross(axis, vector);
        rotated = vector + w * t + cross(axis, t);
    end
end

function position = random_position(lower, upper)
position = lower + rand(3, 1) .* (upper - lower);
end

function filtered = applyResponseFilters(data, impulseResponse, excitation, dt)
data = double(data);
wasVector = isvector(data);
if wasVector
    data = data(:);
end
filtered = zeros(size(data, 1) + numel(impulseResponse) * 2 + numel(excitation) - 3, size(data, 2));
for channelIndex = 1:size(data, 2)
    response = conv(data(:, channelIndex), double(impulseResponse)) * dt;
    response = conv(response, double(impulseResponse)) * dt;
    response = conv(response, double(excitation)) * dt;
    filtered(:, channelIndex) = response;
end
if wasVector
    filtered = filtered(:, 1);
end
end

function validate_fieldii_rectangle(rectData, expectedPosition, expectedFrame, expectedSize, tolerance, angleTolerance)
actualPosition = rectData(8:10, 1);
actualCorners = reshape(rectData(11:22, 1), 4, 3)';
actualSize = [norm(actualCorners(:, 2) - actualCorners(:, 1)); norm(actualCorners(:, 3) - actualCorners(:, 2))];
halfWidth = expectedSize(1) / 2;
halfHeight = expectedSize(2) / 2;
u = expectedFrame(:, 1) * halfWidth;
v = expectedFrame(:, 2) * halfHeight;
expectedCorners = [expectedPosition - u - v, expectedPosition - u + v, ...
    expectedPosition + u + v, expectedPosition + u - v];
actualNormal = cross(actualCorners(:, 2) - actualCorners(:, 1), actualCorners(:, 3) - actualCorners(:, 2));
actualNormal = actualNormal / norm(actualNormal);
expectedNormal = expectedFrame(:, 3);
assert(norm(actualPosition - expectedPosition) <= tolerance, ...
    'Field II rectangle center differs beyond tolerance.');
assert(norm(actualSize - expectedSize) <= tolerance, ...
    'Field II rectangle size differs beyond tolerance.');
assert(max(vecnorm(actualCorners - expectedCorners, 2, 1)) <= tolerance, ...
    'Field II rectangle corners differ beyond tolerance.');
assert(abs(dot(actualNormal, expectedNormal)) >= cos(angleTolerance), ...
    'Field II rectangle normal axis differs beyond angular tolerance.');
end

function validate_fieldii_axis(rectData, expectedPosition, expectedFrame, angleTolerance)
actualPosition = rectData(8:10, 1);
assert(norm(actualPosition - expectedPosition) <= 1e-9, ...
    'Field II array rectangle center differs beyond tolerance.');
end

function [fieldAligned, cpuAligned, gpuAligned, times] = align_signals(cpuData, cpuStartTime, gpuData, gpuStartTime, fieldData, fieldStartTime, fs)
commonStart = max([cpuStartTime, gpuStartTime, fieldStartTime]);
commonEnd = min([cpuStartTime + (size(cpuData, 1) - 1) / fs, ...
    gpuStartTime + (size(gpuData, 1) - 1) / fs, fieldStartTime + (size(fieldData, 1) - 1) / fs]);
times = (commonStart:1 / fs:commonEnd)';
fieldAligned = interp1(fieldStartTime + (0:size(fieldData, 1) - 1) / fs, fieldData, times, 'linear', 0);
cpuAligned = interp1(cpuStartTime + (0:size(cpuData, 1) - 1) / fs, cpuData, times, 'linear', 0);
gpuAligned = interp1(gpuStartTime + (0:size(gpuData, 1) - 1) / fs, gpuData, times, 'linear', 0);
end

function plotHandles = plot_case(times, fieldData, cpuData, gpuData, caseIndex, scatterPosition, transmitPosition, receivePosition, transmitOrientation, receiveOrientation, axesHandle, plotSubtitle)
times = times(:);
fieldData = fieldData(:);
cpuData = cpuData(:);
gpuData = gpuData(:);
sampleCount = min([numel(times), numel(fieldData), numel(cpuData), numel(gpuData)]);
times = times(1:sampleCount);
fieldData = fieldData(1:sampleCount);
cpuData = cpuData(1:sampleCount);
gpuData = gpuData(1:sampleCount);
fprintf('plot case=%d peak FieldII=%e CPU=%e GPU=%e\n', caseIndex, ...
    max(abs(fieldData)), max(abs(cpuData)), max(abs(gpuData)));
if nargin < 11
    figure('Name', sprintf('One rectangle case %d', caseIndex));
    axesHandle = gca;
end
axes(axesHandle);
colororder(colorcet('L16', 'N', 4));
plotHandles = plot(times * 1e6, fieldData, '-', times * 1e6, cpuData, '--', times * 1e6, gpuData, ':');
plotHandles(1).LineWidth = 4*3.0;
plotHandles(2).LineWidth = 4*2.0;
plotHandles(3).LineWidth = 4*1.0;
if nargin >= 11
    signalValues = [fieldData; cpuData; gpuData];
    signalValues = signalValues(isfinite(signalValues));
    signalMinimum = min(signalValues);
    signalMaximum = max(signalValues);
    signalMargin = max((signalMaximum - signalMinimum) * 0.08, eps(max(abs([signalMinimum, signalMaximum]))));
    ylim(axesHandle, [signalMinimum - signalMargin, signalMaximum + signalMargin]);
end
if nargin >= 11
    legend(axesHandle, 'off');
else
    legend('Field II', 'Ekhos CPU', 'Ekhos GPU');
end
if nargin >= 12
    subtitle(axesHandle, plotSubtitle);
end
xlabel('Time (us)');
end

function freeApertures(transmitAperture, receiveAperture)
fieldII.xdc_free(transmitAperture);
fieldII.xdc_free(receiveAperture);
end
