%% Compare Ekhos GPU output against Field II ground truth
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
plotScale = 1e30;
impulseResponse = GetImpulseResponse(single(fc), single(fs));
excitation = sin(2 * pi * (0:dt:cycleCount / fc) * fc);
rowCount = 1;
columnCount = 128;
dieWidth = 2.2e-4;
dieKerf = 3e-5;
elementPitch = dieWidth + dieKerf;
scatterCounts = [1, 2, 4, 8, 16, 32, 64];
plotting = true;
plotScatterCount = scatterCounts(end);
plotCorrelationThreshold = 1;

rng(0, 'twister');
allScatterPositions = [
    rand(1, max(scatterCounts)) * 16e-3 - 8e-3;
    rand(1, max(scatterCounts)) * 16e-3 - 8e-3;
    rand(1, max(scatterCounts)) * 90e-3 + 10e-3;
    ];
allScatterAmplitudes = ones(1, max(scatterCounts));

fieldII.field_init(-1);
fieldII.set_field('c', c);
fieldII.set_field('fs', fs);

tTh = fieldII.xdc_linear_array(columnCount, dieWidth, dieWidth * rowCount, dieKerf, 1, rowCount, [0, 0, 1e10]);
rTh = fieldII.xdc_linear_array(columnCount, dieWidth, dieWidth * rowCount, dieKerf, 1, rowCount, [0, 0, 1e10]);
fieldII.xdc_impulse(tTh, 1);
fieldII.xdc_impulse(rTh, 1);
fieldII.xdc_excitation(tTh, 1);
fieldII.xdc_apodization(tTh, 0, ones(1, columnCount));
fieldII.xdc_apodization(rTh, 0, ones(1, columnCount));

% Match the Odin linear-array test: transmit elements first, receive elements second.
elementCount = 2 * columnCount;
elementPositions = zeros(3, elementCount, 'single');
elementPositions(1, :) = single(repmat(((0:columnCount-1) - (columnCount-1)/2) * elementPitch, 1, 2));
elementOrientations = repmat(single([0; 0; 0; 1]), 1, elementCount);
elementSizes = repmat(single([dieWidth; dieWidth]), 1, elementCount);
elementApodizations = ones(1, elementCount, 'single');
elementDelays = zeros(1, elementCount, 'single');

transmit = ekhos.TransmissionSet();
transmit.Count = uint32(1);
transmit.ElementCounts = uint32(columnCount);
transmit.Indices = int32(1:columnCount);
transmit.Apodizations = ones(1, columnCount, 'single');
transmit.Delays = zeros(1, columnCount, 'single');
transmit.Impulse = ones(1, transmit.Count, 'uint16');
transmit.Excitation = ones(1, transmit.Count, 'uint16');

receiveChannels = ekhos.ReceiveChannelSet();
receiveChannels.Count = uint32(columnCount);
receiveChannels.ElementCounts = repmat(uint32(1), 1, columnCount);
receiveChannels.Indices = int32(columnCount + (1:columnCount));
receiveChannels.Apodizations = ones(1, columnCount, 'single');
receiveChannels.Delays = zeros(1, columnCount, 'single');
receiveChannels.Impulse = ones(1, receiveChannels.Count, 'uint16');

results = struct('scatterCount', cell(size(scatterCounts)), 'cpu', cell(size(scatterCounts)), ...
    'gpu', cell(size(scatterCounts)), 'cpuGpu', cell(size(scatterCounts)));
plotData = struct();

for resultIndex = 1:numel(scatterCounts)
    scatterCount = scatterCounts(resultIndex);
    scatterPositions = allScatterPositions(:, 1:scatterCount);
    scatterAmplitudes = allScatterAmplitudes(1:scatterCount);
    [fieldData, fieldStartTime] = fieldII.calc_scat_multi(tTh, rTh, scatterPositions', scatterAmplitudes');
    fieldData = applyResponseFilters(double(fieldData), impulseResponse, excitation, dt) * plotScale;
    fieldTimes = fieldStartTime + (0:size(fieldData, 1)-1) / fs;
    fieldTimes = double(fieldTimes);
    results(resultIndex).scatterCount = scatterCount;
    for simulatorType = [ekhos.SimulatorType.CPU, ekhos.SimulatorType.GPU]
        simulation = ekhos.Simulation();
        simulation.SimulatorType = simulatorType;
        simulation.Cumulative = true;
        simulation.SamplingFrequency = single(fs);
        simulation.SpeedOfSound = single(c);
        simulation.Impulses = {single(impulseResponse)};
        simulation.Excitations = {single(excitation)};
        simulation.Elements = ekhos.RectangularElementSet();
        simulation.Elements.Count = uint32(elementCount);
        simulation.Elements.Positions = elementPositions;
        simulation.Elements.Orientations = elementOrientations;
        simulation.Elements.Sizes = elementSizes;
        simulation.Elements.Apodizations = elementApodizations;
        simulation.Elements.Delays = elementDelays;
        simulation.Transmissions = transmit;
        simulation.ReceiveChannels = receiveChannels;
        simulation.Scatters = ekhos.ScatterSet();
        simulation.Scatters.Count = uint32(scatterCount);
        simulation.Scatters.Positions = single(scatterPositions);
        simulation.Scatters.Amplitudes = single(scatterAmplitudes);

        vkData = simulation.call();
        vkData = squeeze(double(vkData(:, :, 1))) * plotScale;
        vkTimes = double(simulation.StartTime) + (0:size(vkData, 1) - 1) / fs;
        [fieldAligned, vkAligned, commonTimes] = align_signal_union(vkData, vkTimes, fieldData, fieldTimes, fs);
        metrics = compareSignals(vkAligned, fieldAligned);
        metrics.startTime = simulation.StartTime;
        metrics.sampleCount = simulation.SampleCount;
        metrics.times = commonTimes;

        if simulatorType == ekhos.SimulatorType.CPU
            results(resultIndex).cpu = metrics;
        else
            results(resultIndex).gpu = metrics;
        end
    end

    cpuData = results(resultIndex).cpu;
    gpuData = results(resultIndex).gpu;
    [cpuAligned, gpuAligned, commonTimes] = align_signal_union(cpuData.aligned, cpuData.times, gpuData.aligned, gpuData.times, fs);
    results(resultIndex).cpuGpu = compareSignals(cpuAligned, gpuAligned);
    fprintf(['scatterCount=%d FieldII/CPU energy=%.4g peak=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%; ', ...
        'FieldII/GPU energy=%.4g peak=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%; ', ...
        'CPU/GPU energy=%.4g peak=%.4g corr=%.6f maxRelDiff=%.2f%% rmsErr=%.2f%%\n'], ...
        scatterCount, cpuData.differenceEnergyRatio, cpuData.peakRatio, cpuData.correlation, ...
        cpuData.maxRelativeDifference, cpuData.rmsErrorPercent, ...
        gpuData.differenceEnergyRatio, gpuData.peakRatio, gpuData.correlation, ...
        gpuData.maxRelativeDifference, gpuData.rmsErrorPercent, ...
        results(resultIndex).cpuGpu.differenceEnergyRatio, results(resultIndex).cpuGpu.peakRatio, ...
        results(resultIndex).cpuGpu.correlation, results(resultIndex).cpuGpu.maxRelativeDifference, ...
        results(resultIndex).cpuGpu.rmsErrorPercent);

    if plotting && scatterCount == plotScatterCount && results(resultIndex).cpuGpu.correlation < plotCorrelationThreshold
        plotData.field = fieldAligned;
        plotData.cpu = cpuAligned;
        plotData.gpu = gpuAligned;
        plotData.times = commonTimes;
    end
end

if plotting
    plotTimes = plotData.times * 1e6;
    comparisonFigure = figure('Name', sprintf('Linear array comparison, %d scatterers', plotScatterCount));
    colormap(comparisonFigure, colorcet('L16', 'N', 256));
    tiledlayout(1, 3, 'TileSpacing', 'none', 'Padding', 'none');
    nexttile;
    imagesc(1:columnCount, plotTimes, plotData.field);
    title('Field II');
    xlabel('Receive channel');
    ylabel('Time (us)');
    colorbar;
    nexttile;
    imagesc(1:columnCount, plotTimes, plotData.cpu);
    title('Ekhos CPU');
    xlabel('Receive channel');
    colorbar;
    nexttile;
    imagesc(1:columnCount, plotTimes, plotData.gpu);
    title('Ekhos GPU');
    xlabel('Receive channel');
    colorbar;

    traceFigure = figure('Name', sprintf('Linear array traces, %d scatterers', plotScatterCount));
    traceVideoPath = fullfile(repositoryDirectory, 'figures', ...
        sprintf('linearArrayComparison-%d-scatterers.mp4', plotScatterCount));
    traceVideo = VideoWriter(traceVideoPath, 'MPEG-4');
    traceVideo.FrameRate = 30;
    open(traceVideo);
    cleanupVideo = onCleanup(@() close(traceVideo));

    traceMinimum = min([plotData.field(:); plotData.cpu(:); plotData.gpu(:)]);
    traceMaximum = max([plotData.field(:); plotData.cpu(:); plotData.gpu(:)]);
    tracePadding = 0.05 * max(traceMaximum - traceMinimum, eps("double"));
    traceLimits = [traceMinimum - tracePadding, traceMaximum + tracePadding];
    channelsPerFrame = 4;
    for firstChannel = 1:channelsPerFrame:columnCount
        clf(traceFigure);
        traceLayout = tiledlayout(traceFigure, channelsPerFrame, 1, ...
            'TileSpacing', 'none', 'Padding', 'none');
        for tileIndex = 1:channelsPerFrame
            channelIndex = firstChannel + tileIndex - 1;
            if channelIndex > columnCount
                break;
            end
            nexttile(traceLayout);
            colororder(colorcet('L16', 'N', 3));
            plot(plotTimes, plotData.field(:, channelIndex), '-', ...
                plotTimes, plotData.cpu(:, channelIndex), '--', ...
                plotTimes, plotData.gpu(:, channelIndex), ':');
            ylim(traceLimits);
            ylabel(sprintf('Rx %d', channelIndex));
            if tileIndex == channelsPerFrame || channelIndex == columnCount
                xlabel('Time (us)');
            else
                set(gca, 'XTickLabel', []);
            end
            if tileIndex == 1
                legend('Field II', 'Ekhos CPU', 'Ekhos GPU');
            end
        end
        drawnow;
        writeVideo(traceVideo, getframe(traceFigure));
    end
    close(traceVideo);
    clear cleanupVideo;
end

function metrics = compareSignals(actual, reference)
metrics = signal_metrics(actual, reference);
metrics.aligned = actual;
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

function [firstAligned, secondAligned, times] = align_signal_union(firstData, firstTimes, secondData, secondTimes, fs)
firstTimes = double(firstTimes(:));
secondTimes = double(secondTimes(:));
commonStart = min(firstTimes(1), secondTimes(1));
commonEnd = max(firstTimes(end), secondTimes(end));
times = (commonStart:1 / fs:commonEnd)';
firstAligned = interp1(firstTimes, firstData, times, 'linear', 0);
secondAligned = interp1(secondTimes, secondData, times, 'linear', 0);
end

function freeApertures(transmitAperture, receiveAperture)
fieldII.xdc_free(transmitAperture);
fieldII.xdc_free(receiveAperture);
end
