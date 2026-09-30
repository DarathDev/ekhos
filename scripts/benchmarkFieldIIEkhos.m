%% Benchmark Field II against Ekhos CPU and GPU.
% The benchmark varies physical element count, scatter count, receive-channel
% grouping, and the number of transmissions. Results are written to a table
% and saved as a MAT file in the figures directory.

scriptDirectory = fileparts(mfilename("fullpath"));
repositoryDirectory = fileparts(scriptDirectory);
addpath(repositoryDirectory);
addpath(fullfile(repositoryDirectory, "matlab"));
addpath(fullfile(scriptDirectory, "color"));

%% Benchmark settings
fs = single(100e6);
c = single(1540);
fc = single(5e6);
cycleCount = 2;

% Compare linear and matrix arrays with the same row and column counts.
linearSideLengths = [128];
matrixSideLengths = [32];
matrixReceiveGroupSizes = 1;
scatterCounts = 2.^(7:18);
scatterDepthRange = [20e-3, 100e-3];
transmissionCounts = [1];
repetitions = 1;
minimumCorrelation = 0.98;

runCPU = true;
runGPU = true;
writeResults = true;
quickMode = false;
quickModeOverride = getenv("EKHOS_QUICK_MODE");
if ~isempty(quickModeOverride)
    quickMode = logical(str2double(quickModeOverride));
end
rng(0, "twister");
hardware = getHardwareInfo();

if quickMode
    linearSideLengths = [32, 64];
    matrixSideLengths = [8, 16];
    matrixReceiveGroupSizes = 1;
    scatterCounts = [128, 1024];
    transmissionCounts = 1;
end

scatterCountOverride = str2num(getenv("EKHOS_SCATTER_COUNTS")); %#ok<ST2NM>
if ~isempty(scatterCountOverride)
    scatterCounts = scatterCountOverride;
end
matrixSizeOverride = str2num(getenv("EKHOS_MATRIX_SIZES")); %#ok<ST2NM>
if ~isempty(matrixSizeOverride)
    matrixSideLengths = matrixSizeOverride;
end
linearSizeOverride = str2num(getenv("EKHOS_LINEAR_SIZES")); %#ok<ST2NM>
if ~isempty(linearSizeOverride) || ~isempty(getenv("EKHOS_LINEAR_SIZES"))
    linearSideLengths = linearSizeOverride;
end
scatterDepthOverride = str2num(getenv("EKHOS_SCATTER_DEPTH_MM")); %#ok<ST2NM>
if numel(scatterDepthOverride) == 2 && scatterDepthOverride(2) > scatterDepthOverride(1)
    scatterDepthRange = scatterDepthOverride * 1e-3;
end
runCPUOverride = getenv("EKHOS_RUN_CPU");
if ~isempty(runCPUOverride)
    runCPU = logical(str2double(runCPUOverride));
end
runGPUOverride = getenv("EKHOS_RUN_GPU");
if ~isempty(runGPUOverride)
    runGPU = logical(str2double(runGPUOverride));
end
writeResultsOverride = getenv("EKHOS_WRITE_RESULTS");
if ~isempty(writeResultsOverride)
    writeResults = logical(str2double(writeResultsOverride));
end
replotResultsPath = getenv("EKHOS_REPLOT_RESULTS");
if ~isempty(replotResultsPath)
    loadedResults = load(replotResultsPath, "results", "hardware");
    outputDirectory = fullfile(repositoryDirectory, "figures");
    if ~isfolder(outputDirectory)
        mkdir(outputDirectory);
    end
    timestamp = string(datetime("now", "Format", "yyyyMMdd-HHmmss"));
    saveBenchmarkFigures(loadedResults.results, loadedResults.hardware, outputDirectory, timestamp);
    fprintf("Replotted benchmark results from %s\n", replotResultsPath);
    return;
end
reportOutputStats = false;
reportOutputStatsOverride = getenv("EKHOS_REPORT_OUTPUT_STATS");
if ~isempty(reportOutputStatsOverride)
    reportOutputStats = logical(str2double(reportOutputStatsOverride));
end
failOnCorrelation = true;
failOnCorrelationOverride = getenv("EKHOS_FAIL_ON_CORRELATION");
if ~isempty(failOnCorrelationOverride)
    failOnCorrelation = logical(str2double(failOnCorrelationOverride));
end
fieldIICacheEnabled = true;
fieldIICacheOverride = getenv("EKHOS_FIELDII_CACHE");
if ~isempty(fieldIICacheOverride)
    fieldIICacheEnabled = logical(str2double(fieldIICacheOverride));
end
skipFieldII = false;
skipFieldIIOverride = getenv("EKHOS_SKIP_FIELDII");
if ~isempty(skipFieldIIOverride)
    skipFieldII = logical(str2double(skipFieldIIOverride));
end
fieldIICachePath = getenv("EKHOS_FIELDII_CACHE_PATH");
if isempty(fieldIICachePath)
    fieldIICachePath = fullfile(repositoryDirectory, "figures", "fieldII-reference-cache.mat");
end
fieldIICache = loadFieldIICache(fieldIICachePath, fieldIICacheEnabled);

impulseResponse = GetImpulseResponse(fc, fs);
excitation = sin(2 * pi * (0:1 / double(fs):cycleCount / double(fc)) * double(fc));

results = table();
fieldII.field_init(-1);
fieldII.set_field('c', double(c));
fieldII.set_field('fs', double(fs));

% Prepare every Field II case before starting any Ekhos simulations. Each
% prepared record contains all inputs needed to reproduce the comparison.
preparedCases = struct("key", {}, "arrayKind", {}, "rowCount", {}, ...
    "columnCount", {}, "elementCount", {}, "scatterCount", {}, ...
    "transmissionCount", {}, "scatterPositions", {}, "scatterAmplitudes", {}, ...
    "fieldIIData", {}, "fieldIITimingData", {}, "fieldIITime", {}, "fieldIIChannelCount", {}, ...
    "fieldIIStartTimes", {}, "transmitGeometry", {}, "receiveGeometry", {});
for arrayKind = ["linear", "matrix"]
    if strcmp(arrayKind, "linear")
        arraySizes = linearSideLengths;
    else
        arraySizes = matrixSideLengths;
    end

    for arraySize = arraySizes
        if arrayKind == "linear"
            rowCount = arraySize;
            columnCount = arraySize;
            elementCount = rowCount * columnCount;
            receiveGroupSizes = rowCount;
        else
            rowCount = arraySize;
            columnCount = arraySize;
            elementCount = rowCount * columnCount;
            receiveGroupSizes = matrixReceiveGroupSizes;
        end

        rng(0, "twister");
        if skipFieldII && arrayKind == "matrix"
            makeScatterPositions(max(scatterCounts), scatterDepthRange);
        end
        allScatterPositions = makeScatterPositions(max(scatterCounts), scatterDepthRange);
        allScatterAmplitudes = ones(max(scatterCounts), 1, "single");

        for scatterCount = scatterCounts
            scatterPositions = allScatterPositions(:, 1:scatterCount);
            scatterAmplitudes = allScatterAmplitudes(1:scatterCount);
            for transmissionCount = transmissionCounts
                fieldIICacheKey = makeFieldIICacheKey(...
                    arrayKind, rowCount, columnCount, scatterCount, max(scatterCounts), scatterDepthRange, ...
                    transmissionCount, fs, c, fc, cycleCount);
                cacheIndex = find(string({fieldIICache.key}) == string(fieldIICacheKey), 1, "last");
                if isempty(cacheIndex)
                    legacyFieldIICacheKey = makeLegacyFieldIICacheKey(...
                        arrayKind, rowCount, columnCount, scatterCount, scatterDepthRange, ...
                        transmissionCount, fs, c, fc, cycleCount);
                    cacheIndex = find(string({fieldIICache.key}) == string(legacyFieldIICacheKey), 1, "last");
                end
                cacheHasScatterInputs = ~isempty(cacheIndex) && ...
                    ~isempty(fieldIICache(cacheIndex).scatterPositions) && ...
                    ~isempty(fieldIICache(cacheIndex).scatterAmplitudes);
                if skipFieldII && (~cacheHasScatterInputs)
                    error("EKHOS_SKIP_FIELDII=1 requires a cached Field II reference for %s.", fieldIICacheKey);
                end
                if fieldIICacheEnabled && cacheHasScatterInputs
                    cachedReference = fieldIICache(cacheIndex);
                    fieldIIData = cachedReference.data;
                    fieldIITimingData = cachedReference.timingData;
                    fieldIITime = cachedReference.elapsed;
                    fieldIIChannelCount = cachedReference.channelCount;
                    fieldIIStartTimes = cachedReference.startTimes;
                    transmitGeometry = cachedReference.transmitGeometry;
                    receiveGeometry = cachedReference.receiveGeometry;
                    if ~isempty(cachedReference.scatterPositions)
                        scatterPositions = cachedReference.scatterPositions;
                        scatterAmplitudes = cachedReference.scatterAmplitudes;
                    end
                    fprintf("Field II cache hit: %s\n", fieldIICacheKey);
                else
                    fprintf("Field II simulation: %s\n", fieldIICacheKey);
                    [fieldIIData, fieldIITimingData, fieldIITime, fieldIIChannelCount, fieldIIStartTimes, transmitGeometry, receiveGeometry] = runFieldII(...
                        arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
                        transmissionCount, impulseResponse, excitation);
                    if fieldIICacheEnabled
                        fieldIICache(end + 1) = makeFieldIICacheEntry(...
                            fieldIICacheKey, fieldIIData, fieldIITimingData, fieldIITime, fieldIIChannelCount, fieldIIStartTimes, ...
                            transmitGeometry, receiveGeometry, scatterPositions, scatterAmplitudes);
                        saveFieldIICache(fieldIICachePath, fieldIICache);
                    end
                end
                preparedCases(end + 1) = makePreparedCase(...
                    fieldIICacheKey, arrayKind, rowCount, columnCount, elementCount, scatterCount, transmissionCount, ...
                    scatterPositions, scatterAmplitudes, fieldIIData, fieldIITimingData, fieldIITime, fieldIIChannelCount, ...
                    fieldIIStartTimes, transmitGeometry, receiveGeometry); %#ok<AGROW>
            end
        end
    end
end

fieldII.field_end();
ekhos.LoadLibraries();
fprintf("Field II preparation complete for %d cases; starting Ekhos phase\n", numel(preparedCases));
    for preparedCase = preparedCases
        arrayKind = preparedCase.arrayKind;
        elementCount = preparedCase.elementCount;
        if arrayKind == "linear"
            receiveGroupSizes = preparedCase.rowCount;
        else
            receiveGroupSizes = matrixReceiveGroupSizes;
        end
        for receiveGroupSize = receiveGroupSizes
            if mod(elementCount, receiveGroupSize) ~= 0
                continue;
            end
            receiveChannelCount = elementCount / receiveGroupSize;
            if arrayKind == "linear"
                receiveIndices = makeReceiveIndices(preparedCase.receiveGeometry, receiveGroupSize);
                fieldIIGrouped = groupSignals( ...
                    preparedCase.fieldIIData(:, receiveIndices, :), receiveGroupSize);
            else
                fieldIIGrouped = groupSignals(preparedCase.fieldIIData, receiveGroupSize);
            end
            assert(size(fieldIIGrouped, 2) == receiveChannelCount, ...
                "Field II grouping produced %d channels for %s group %d; expected %d.", ...
                size(fieldIIGrouped, 2), arrayKind, receiveGroupSize, receiveChannelCount);
            if arrayKind == "linear"
                fieldIITimingGrouped = preparedCase.fieldIITimingData;
            else
                fieldIITimingGrouped = fieldIIGrouped;
            end
            phases = struct("label", {}, "simulatorType", {}, "threadCount", {}, "cpuScatterFraction", {});
            if runCPU
                phases(end + 1) = struct("label", "Ekhos CPU", ...
                    "simulatorType", ekhos.SimulatorType.CPU, "threadCount", uint16(1), "cpuScatterFraction", single(0));
                phases(end + 1) = struct("label", "Ekhos CPU (all cores)", ...
                    "simulatorType", ekhos.SimulatorType.CPU, "threadCount", uint16(0), "cpuScatterFraction", single(0));
            end
            if runGPU
                phases(end + 1) = struct("label", "Ekhos GPU", ...
                    "simulatorType", ekhos.SimulatorType.GPU, "threadCount", uint16(1), "cpuScatterFraction", single(0));
            end
            if runCPU && runGPU
                phases(end + 1) = struct("label", "Ekhos Hybrid", ...
                    "simulatorType", ekhos.SimulatorType.Hybrid, "threadCount", uint16(0), "cpuScatterFraction", single(NaN));
            end
            fprintf("%s elements=%d group=%d scatters=%d transmissions=%d\n", ...
                arrayKind, elementCount, receiveGroupSize, preparedCase.scatterCount, preparedCase.transmissionCount);
            phaseResults = struct("label", {}, "wallTime", {});
            for repetitionIndex = 1:repetitions
                for phaseIndex = 1:numel(phases)
                    phase = phases(phaseIndex);
                    cpuScatterFraction = phase.cpuScatterFraction;
                    if phase.simulatorType == ekhos.SimulatorType.Hybrid
                        phaseLabels = [phaseResults.label];
                        cpuTime = phaseResults(phaseLabels == "Ekhos CPU (all cores)").wallTime;
                        gpuTime = phaseResults(phaseLabels == "Ekhos GPU").wallTime;
                        cpuScatterFraction = single(gpuTime / (cpuTime + gpuTime));
                        fprintf("  Hybrid CPU scatter fraction=%.4f (CPU=%.4fs GPU=%.4fs)\n", ...
                            cpuScatterFraction, cpuTime, gpuTime);
                    end
                    simulation = makeVkSimulation(...
                        preparedCase.transmitGeometry, preparedCase.receiveGeometry, preparedCase.scatterPositions, preparedCase.scatterAmplitudes, ...
                        receiveGroupSize, preparedCase.transmissionCount, phase.simulatorType, phase.threadCount, cpuScatterFraction, ...
                        fs, c, impulseResponse, excitation);
                    fprintf("  %s simulation started\n", phase.label);
                    timer = tic();
                    vkData = simulation.call();
                    wallTime = toc(timer);
                    fprintf("  %s simulation complete in %.4fs\n", phase.label, wallTime);
                    phaseResults(phaseIndex) = struct("label", phase.label, "wallTime", wallTime);
                    vkData = double(vkData);
                    if ismatrix(vkData)
                        vkData = reshape(vkData, size(vkData, 1), size(vkData, 2), 1);
                    end
                    vkData = vkData * (1 / double(fs));
                    if reportOutputStats && phase.simulatorType == ekhos.SimulatorType.GPU
                        fprintf("  GPU output min=%g max=%g norm=%g nonzero=%d\n", ...
                            min(vkData, [], "all"), max(vkData, [], "all"), norm(vkData(:)), nnz(vkData));
                    end
                    fieldIIDataScaled = fieldIIGrouped * (1 / double(fs));
                    outputCorrelation = compareSimulationOutputs(...
                        fieldIIDataScaled, preparedCase.fieldIIStartTimes, vkData, simulation.StartTime, fs);
                    fprintf("  %s correlation=%.4f (required %.2f)\n", phase.label, outputCorrelation, minimumCorrelation);
                    if arrayKind == "linear"
                        linearCorrelation = compareSimulationOutputs(...
                            fieldIITimingGrouped * (1 / double(fs)), ...
                            preparedCase.fieldIIStartTimes, vkData, simulation.StartTime, fs);
                        fprintf("  %s linear-array correlation=%.4f\n", phase.label, linearCorrelation);
                    end
                    if failOnCorrelation
                        assert(outputCorrelation >= minimumCorrelation, ...
                            "Field II and %s outputs have correlation %.4f, below the %.2f threshold.", ...
                            phase.label, outputCorrelation, minimumCorrelation);
                    end
                    row = table(string(arrayKind), string(phase.label), elementCount, ...
                        receiveGroupSize, receiveChannelCount, preparedCase.scatterCount, preparedCase.transmissionCount, ...
                        preparedCase.fieldIIChannelCount, preparedCase.fieldIITime, wallTime, simulation.Metrics.SimulationTime, ...
                        outputCorrelation, size(fieldIIGrouped, 1), size(vkData, 1), repetitionIndex, ...
                        'VariableNames', {'arrayKind', 'simulator', 'elementCount', 'receiveGroupSize', 'receiveChannelCount', ...
                        'scatterCount', 'transmissionCount', 'fieldIIChannelCount', 'fieldIISeconds', 'wallSeconds', ...
                        'simulationSeconds', 'outputCorrelation', 'fieldIISampleCount', 'vkSampleCount', 'repetition'});
                    row.cpuScatterFraction = double(cpuScatterFraction);
                    results = [results; row]; %#ok<AGROW>
                    fprintf("  repetition=%d %s FieldII=%.4fs wall=%.4fs simulation=%.4fs speedup=%.2fx\n", ...
                        repetitionIndex, phase.label, preparedCase.fieldIITime, wallTime, ...
                        double(simulation.Metrics.SimulationTime), preparedCase.fieldIITime / wallTime);
                end
            end
        end
    end

if writeResults
    outputDirectory = fullfile(repositoryDirectory, "figures");
    if ~isfolder(outputDirectory)
        mkdir(outputDirectory);
    end
    timestamp = string(datetime("now", "Format", "yyyyMMdd-HHmmss"));
    writetable(results, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + ".csv"));
    save(fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + ".mat"), "results", "hardware");
    saveBenchmarkFigures(results, hardware, outputDirectory, timestamp);
end

%% Local functions
function positions = makeScatterPositions(scatterCount, depthRange)
positions = [
    rand(1, scatterCount, "single") * 16e-3 - 8e-3;
    rand(1, scatterCount, "single") * 4e-3 - 2e-3;
    rand(1, scatterCount, "single") * (depthRange(2) - depthRange(1)) + depthRange(1);
    ];
end

function key = makeFieldIICacheKey(...
    arrayKind, rowCount, columnCount, scatterCount, maximumScatterCount, scatterDepthRange, ...
    transmissionCount, samplingFrequency, speedOfSound, centerFrequency, cycleCount)
key = sprintf("v5-%s-%d-%d-%d-%d-%.9g-%.9g-%d-%.9g-%.9g-%.9g-%d", ...
    arrayKind, rowCount, columnCount, scatterCount, maximumScatterCount, scatterDepthRange(1), ...
    scatterDepthRange(2), transmissionCount, double(samplingFrequency), ...
    double(speedOfSound), double(centerFrequency), cycleCount);
end

function key = makeLegacyFieldIICacheKey(...
    arrayKind, rowCount, columnCount, scatterCount, scatterDepthRange, ...
    transmissionCount, samplingFrequency, speedOfSound, centerFrequency, cycleCount)
key = sprintf("%s-%d-%d-%d-%.9g-%.9g-%d-%.9g-%.9g-%.9g-%d", ...
    arrayKind, rowCount, columnCount, scatterCount, scatterDepthRange(1), ...
    scatterDepthRange(2), transmissionCount, double(samplingFrequency), ...
    double(speedOfSound), double(centerFrequency), cycleCount);
end

function cache = loadFieldIICache(cachePath, enabled)
cache = struct("key", {}, "data", {}, "timingData", {}, "elapsed", {}, "channelCount", {}, ...
    "startTimes", {}, "transmitGeometry", {}, "receiveGeometry", {}, ...
    "scatterPositions", {}, "scatterAmplitudes", {});
if ~enabled || ~isfile(cachePath)
    return;
end
try
    loaded = load(cachePath, "fieldIICache");
catch exception
    warning("Ekhos:InvalidFieldIICache", ...
        "Ignoring unreadable Field II cache %s: %s", cachePath, exception.message);
    return;
end
if isfield(loaded, "fieldIICache")
    cache = loaded.fieldIICache;
    if ~isfield(cache, "timingData")
        [cache.timingData] = deal([]);
    end
    if ~isfield(cache, "scatterPositions")
        [cache.scatterPositions] = deal([]);
    end
    if ~isfield(cache, "scatterAmplitudes")
        [cache.scatterAmplitudes] = deal([]);
    end
end
end

function entry = makeFieldIICacheEntry(key, data, timingData, elapsed, channelCount, startTimes, ...
    transmitGeometry, receiveGeometry, scatterPositions, scatterAmplitudes)
entry = struct( ...
    "key", key, "data", data, "timingData", timingData, "elapsed", elapsed, "channelCount", channelCount, ...
    "startTimes", startTimes, "transmitGeometry", transmitGeometry, ...
    "receiveGeometry", receiveGeometry, "scatterPositions", scatterPositions, ...
    "scatterAmplitudes", scatterAmplitudes);
end

function preparedCase = makePreparedCase(key, arrayKind, rowCount, columnCount, elementCount, ...
    scatterCount, transmissionCount, scatterPositions, scatterAmplitudes, fieldIIData, fieldIITimingData, fieldIITime, ...
    fieldIIChannelCount, fieldIIStartTimes, transmitGeometry, receiveGeometry)
preparedCase = struct( ...
    "key", key, "arrayKind", arrayKind, "rowCount", rowCount, "columnCount", columnCount, ...
    "elementCount", elementCount, "scatterCount", scatterCount, "transmissionCount", transmissionCount, ...
    "scatterPositions", scatterPositions, "scatterAmplitudes", scatterAmplitudes, ...
    "fieldIIData", fieldIIData, "fieldIITimingData", fieldIITimingData, "fieldIITime", fieldIITime, "fieldIIChannelCount", fieldIIChannelCount, ...
    "fieldIIStartTimes", fieldIIStartTimes, "transmitGeometry", transmitGeometry, ...
    "receiveGeometry", receiveGeometry);
end

function saveFieldIICache(cachePath, cache)
cacheDirectory = fileparts(cachePath);
if ~isempty(cacheDirectory) && ~isfolder(cacheDirectory)
    mkdir(cacheDirectory);
end
fieldIICache = cache; %#ok<NASGU>
save(cachePath, "fieldIICache", "-v7.3");
end

function [data, timingData, elapsed, channelCount, startTimes, transmitGeometry, receiveGeometry] = runFieldII(...
    arrayKind, rowCount, columnCount, scatterPositions, scatterAmplitudes, ...
    transmissionCount, impulseResponse, excitation)
if strcmp(arrayKind, "linear")
    timingTAperture = fieldII.xdc_linear_array(columnCount, 2.2e-4, 2.2e-4 * rowCount, ...
        3e-5, 1, rowCount, [0, 0, 1e10]);
    timingRAperture = fieldII.xdc_linear_array(columnCount, 2.2e-4, 2.2e-4 * rowCount, ...
        3e-5, 1, rowCount, [0, 0, 1e10]);
    tAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 0, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
    rAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 0, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
else
    timingTAperture = [];
    timingRAperture = [];
    tAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 3e-5, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
    rAperture = fieldII.xdc_2d_array(columnCount, rowCount, 2.2e-4, 2.2e-4, ...
        3e-5, 3e-5, ones(rowCount, columnCount)', 1, 1, [0, 0, 1e10]);
end
cleanup = onCleanup(@() freeApertures(tAperture, rAperture, timingTAperture, timingRAperture));
fieldII.xdc_impulse(tAperture, double(impulseResponse));
fieldII.xdc_impulse(rAperture, double(impulseResponse));
fieldII.xdc_excitation(tAperture, double(excitation));
if strcmp(arrayKind, "linear")
    fieldII.xdc_impulse(timingTAperture, double(impulseResponse));
    fieldII.xdc_impulse(timingRAperture, double(impulseResponse));
    fieldII.xdc_excitation(timingTAperture, double(excitation));
    fieldII.xdc_apodization(timingTAperture, 0, ones(1, columnCount));
    fieldII.xdc_apodization(timingRAperture, 0, ones(1, columnCount));
    elementNumbers = (1:columnCount).';
    subelementApodizations = double(ones(columnCount, rowCount));
    subelementDelays = zeros(columnCount, rowCount);
    fieldII.ele_apodization(timingTAperture, elementNumbers, subelementApodizations);
    fieldII.ele_apodization(timingRAperture, elementNumbers, subelementApodizations);
    fieldII.ele_delay(timingTAperture, elementNumbers, subelementDelays);
    fieldII.ele_delay(timingRAperture, elementNumbers, subelementDelays);
    fieldII.xdc_apodization(tAperture, 0, ones(1, columnCount * rowCount));
    fieldII.xdc_apodization(rAperture, 0, ones(1, columnCount * rowCount));
else
    fieldII.xdc_apodization(tAperture, 0, reshape(ones(columnCount, rowCount)', 1, []));
    fieldII.xdc_apodization(rAperture, 0, reshape(ones(columnCount, rowCount)', 1, []));
end
    transmitGeometry = fieldII.xdc_get(tAperture, 'rect');
    receiveGeometry = fieldII.xdc_get(rAperture, 'rect');

fieldIIData = cell(transmissionCount, 1);
fieldIITimingData = cell(transmissionCount, 1);
startTimes = zeros(transmissionCount, 1);
elapsed = 0;
for transmissionIndex = 1:transmissionCount
    if strcmp(arrayKind, "linear")
        timer = tic();
        [fieldIITimingData{transmissionIndex}, timingStartTime] = fieldII.calc_scat_multi(...
            timingTAperture, timingRAperture, double(scatterPositions'), ...
            double(scatterAmplitudes));
        elapsed = elapsed + toc(timer);
    end
    if ~strcmp(arrayKind, "linear")
        timer = tic();
    end
    [fieldIIData{transmissionIndex}, startTimes(transmissionIndex)] = ...
    fieldII.calc_scat_multi(tAperture, rAperture, double(scatterPositions'), double(scatterAmplitudes));
    if ~strcmp(arrayKind, "linear")
        elapsed = elapsed + toc(timer);
    end
    if strcmp(arrayKind, "linear")
        startTimes(transmissionIndex) = timingStartTime;
    end
end
channelCount = size(fieldIIData{1}, 2);
maxSamples = max(cellfun(@(value) size(value, 1), fieldIIData));
data = zeros(maxSamples, channelCount, transmissionCount);
if strcmp(arrayKind, "linear")
    timingChannelCount = size(fieldIITimingData{1}, 2);
    timingMaxSamples = max(cellfun(@(value) size(value, 1), fieldIITimingData));
    timingData = zeros(timingMaxSamples, timingChannelCount, transmissionCount);
else
    timingData = data;
end
for transmissionIndex = 1:transmissionCount
    data(1:size(fieldIIData{transmissionIndex}, 1), :, transmissionIndex) = fieldIIData{transmissionIndex};
    if strcmp(arrayKind, "linear")
        timingData(1:size(fieldIITimingData{transmissionIndex}, 1), :, transmissionIndex) = fieldIITimingData{transmissionIndex};
    else
        timingData = data;
    end
end
end

function minimumCorrelation = compareSimulationOutputs(...
    fieldIIData, fieldIIStartTimes, vkData, vkStartTime, samplingFrequency)
transmissionCount = min(size(fieldIIData, 3), size(vkData, 3));
correlations = zeros(transmissionCount, 1);
for transmissionIndex = 1:transmissionCount
    fieldIITimes = fieldIIStartTimes(transmissionIndex) + ...
        (0:size(fieldIIData, 1) - 1) / double(samplingFrequency);
    vkTimes = double(vkStartTime) + ...
        (0:size(vkData, 1) - 1) / double(samplingFrequency);
    bestCorrelation = -1;
    for sampleOffset = -4:4
        shiftedVkTimes = vkTimes + sampleOffset / double(samplingFrequency);
        commonStart = max(fieldIITimes(1), shiftedVkTimes(1));
        commonEnd = min(fieldIITimes(end), shiftedVkTimes(end));
        commonTimes = (commonStart:1 / double(samplingFrequency):commonEnd)';
        vkAligned = interp1(shiftedVkTimes, vkData(:, :, transmissionIndex), commonTimes, 'linear');
        fieldIIAligned = interp1(fieldIITimes, fieldIIData(:, :, transmissionIndex), commonTimes, 'linear');
        metrics = signal_metrics(vkAligned, fieldIIAligned);
        bestCorrelation = max(bestCorrelation, metrics.correlation);
    end
    correlations(transmissionIndex) = bestCorrelation;
end
minimumCorrelation = min(correlations);
end

function simulation = makeVkSimulation(...
    transmitGeometry, receiveGeometry, scatterPositions, scatterAmplitudes, ...
    receiveGroupSize, transmissionCount, simulatorType, threadCount, cpuScatterFraction, ...
    fs, c, impulseResponse, excitation)
elementCount = size(transmitGeometry, 2);
simulation = ekhos.Simulation();
simulation.Cumulative = true;
simulation.SimulatorType = simulatorType;
simulation.CpuSettings.ThreadCount = threadCount;
simulation.HybridSettings.CpuScatterFraction = cpuScatterFraction;
simulation.SamplingFrequency = fs;
simulation.SpeedOfSound = c;
simulation.Impulses = {single(impulseResponse)};
simulation.Excitations = {single(excitation)};
simulation.Elements = ekhos.RectangularElementSet();
simulation.Elements.Count = uint32(2 * elementCount);
simulation.Elements.Positions = single([transmitGeometry(8:10, :), receiveGeometry(8:10, :)]);
simulation.Elements.Normals = single([tangentsToNormals(transmitGeometry(8:10, :)), ...
    tangentsToNormals(receiveGeometry(8:10, :))]);
simulation.Elements.Sizes = single([transmitGeometry(3:4, :), receiveGeometry(3:4, :)]);
simulation.Elements.Apodizations = single([transmitGeometry(5, :), receiveGeometry(5, :)]);
simulation.Elements.Delays = single([transmitGeometry(23, :), receiveGeometry(23, :)]);

transmissions = ekhos.TransmissionSet();
transmissions.Count = uint32(transmissionCount);
transmissions.ElementCounts = repmat(uint32(elementCount), 1, transmissionCount);
transmissions.Indices = repmat(int32(1:elementCount), 1, transmissionCount);
transmissions.Apodizations = repmat(single(transmitGeometry(5, :)), 1, transmissionCount);
transmissions.Delays = repmat(single(transmitGeometry(23, :)), 1, transmissionCount);
transmissions.Impulse = ones(1, transmissionCount, "uint16");
transmissions.Excitation = ones(1, transmissionCount, "uint16");
simulation.Transmissions = transmissions;

receiveChannelCount = elementCount / receiveGroupSize;
receiveChannels = ekhos.ReceiveChannelSet();
receiveChannels.Count = uint32(receiveChannelCount);
receiveChannels.ElementCounts = repmat(uint32(receiveGroupSize), 1, receiveChannelCount);
receiveChannels.Indices = int32(elementCount + makeReceiveIndices(...
    receiveGeometry, receiveGroupSize));
receiveChannels.Apodizations = single(receiveGeometry(5, :));
receiveChannels.Delays = single(receiveGeometry(23, :));
receiveChannels.Impulse = ones(1, receiveChannelCount, "uint16");
simulation.ReceiveChannels = receiveChannels;

simulation.Scatters = ekhos.ScatterSet();
simulation.Scatters.Count = uint32(size(scatterPositions, 2));
simulation.Scatters.Positions = single(scatterPositions);
simulation.Scatters.Amplitudes = single(scatterAmplitudes);
end

function normals = tangentsToNormals(tangents)
normals = [tangents(2, :)./sqrt(1 + tangents(2, :).^2);
    tangents(1, :)./sqrt(1 + tangents(1, :).^2);
    sqrt(1 - (tangents(1, :).^2).*(tangents(2, :).^2))./sqrt(1 + tangents(1, :).^2)./sqrt(1 + tangents(2, :).^2)];
end

function indices = makeReceiveIndices(receiveGeometry, receiveGroupSize)
if receiveGroupSize == 1
    indices = 1:size(receiveGeometry, 2);
    return;
end
xPositions = receiveGeometry(8, :);
uniqueXPositions = unique(xPositions, "stable");
indices = zeros(1, numel(uniqueXPositions) * receiveGroupSize);
writeIndex = 1;
for xPosition = uniqueXPositions
    group = find(abs(xPositions - xPosition) < eps(max(abs(xPosition), 1)));
    if numel(group) ~= receiveGroupSize
        error("Expected %d receive subelements at x=%g, found %d.", ...
            receiveGroupSize, xPosition, numel(group));
    end
    indices(writeIndex:writeIndex + receiveGroupSize - 1) = group;
    writeIndex = writeIndex + receiveGroupSize;
end
end

function grouped = groupSignals(data, groupSize)
channelCount = size(data, 2);
grouped = reshape(sum(reshape(data, size(data, 1), groupSize, channelCount / groupSize, size(data, 3)), 2), ...
    size(data, 1), channelCount / groupSize, size(data, 3));
end

function freeApertures(transmitAperture, receiveAperture, timingTransmitAperture, timingReceiveAperture)
fieldII.xdc_free(transmitAperture);
fieldII.xdc_free(receiveAperture);
if ~isempty(timingTransmitAperture)
    fieldII.xdc_free(timingTransmitAperture);
    fieldII.xdc_free(timingReceiveAperture);
end
end

function hardware = getHardwareInfo()
if ispc
    [~, cpuName] = system('powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)"');
    [~, gpuName] = system('powershell -NoProfile -Command "(Get-CimInstance Win32_VideoController | Select-Object -First 1 -ExpandProperty Name)"');
    if isempty(strtrim(cpuName))
        [~, cpuName] = system("wmic cpu get Name /value");
    end
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("wmic path win32_VideoController get Name /value");
    end
elseif ismac
    [~, cpuName] = system("system_profiler SPHardwareDataType | sed -n 's/^[[:space:]]*\\(Chip\\|Processor Name\\):[[:space:]]*//p' | head -n 1");
    [~, gpuName] = system("system_profiler SPDisplaysDataType | sed -n 's/^[[:space:]]*Chipset Model:[[:space:]]*//p' | head -n 1");
else
    [~, cpuName] = system("lscpu 2>/dev/null | grep -m1 'Model name' | cut -d: -f2-");
    [~, gpuName] = system("vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName[[:space:]]*=/{name=$2} /deviceType[[:space:]]*=.*DISCRETE_GPU/{print name; exit}' | sed -n 's/^[[:space:]]*//p'");
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName[[:space:]]*[=:][[:space:]]*//p' | head -n 1");
    end
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -n 1");
    end
    if isempty(strtrim(gpuName))
        [~, gpuName] = system("lspci -nn 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' | head -n 1 | sed -E 's/.*: //; s/ \\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\\].*//' ");
    end
end

cpuName = strtrim(cpuName);
if isempty(cpuName)
    cpuName = strtrim(computer());
end
gpuName = strtrim(gpuName);
if isempty(gpuName)
    gpuName = "GPU unavailable";
end
gpuName = regexprep(gpuName, '\s*\([^)]*\)\s*$', '');
gpuName = regexprep(gpuName, '\s*\[[^]]*\]\s*$', '');
gpuTokens = regexp(gpuName, ...
    '(Radeon\s+[^\(\[]+|GeForce\s+[^\(\[]+|Quadro\s+[^\(\[]+|Tesla\s+[^\(\[]+|Arc\s+[^\(\[]+)', ...
    'tokens', 'once', 'ignorecase');
if ~isempty(gpuTokens)
    gpuName = gpuTokens{1};
end
gpuName = strtrim(gpuName);

hardware = struct("cpu", cpuName, "gpu", gpuName);
end

function saveBenchmarkFigures(results, hardware, outputDirectory, timestamp)
hardwareLabel = sprintf("CPU: %s\nGPU: %s", hardware.cpu, hardware.gpu);
resultArrayKinds = string(results{:, 1});
resultSimulators = string(results{:, 2});
resultElementCounts = results{:, 3};
resultReceiveGroupSizes = results{:, 4};
resultScatterCounts = results{:, 6};
resultTransmissionCounts = results{:, 7};
resultFieldIISeconds = results{:, 9};
resultWallSeconds = results{:, 10};
arrayKinds = unique(resultArrayKinds, "stable");
seriesNames = ["Field II", "Ekhos CPU", "Ekhos CPU (all cores)", "Ekhos GPU", "Ekhos Hybrid"];
seriesSimulators = ["", seriesNames(2:end)];
seriesLineWidths = [5, 3.75, 3.25, 2.75, 2.25];
    colorcetColors = colorcet('L16', 'N', 5);
    seriesColors = colorcetColors(1:5, :);
panelCount = 0;
for arrayKind = arrayKinds'
    panelCount = panelCount + numel(unique(resultElementCounts(resultArrayKinds == arrayKind)));
end
panelRows = ceil(sqrt(panelCount));
panelColumns = ceil(panelCount / panelRows);
plotTransmissionCount = 1;

timingFigure = figure("Visible", "off", "Color", "w", "Name", "Ekhos benchmark timing");
panelIndex = 0;
for arrayKind = arrayKinds'
    elementCounts = unique(resultElementCounts(resultArrayKinds == arrayKind));
    for elementCount = elementCounts'
        panelIndex = panelIndex + 1;
        subplot(panelRows, panelColumns, panelIndex);
    axesHandle = gca;
    axesHandle.Color = "w";
    axesHandle.XColor = "k";
    axesHandle.YColor = "k";
    axesHandle.Title.Color = "k";
    axesHandle.XLabel.Color = "k";
    axesHandle.YLabel.Color = "k";
    axesHandle.GridColor = [0.7, 0.7, 0.7];
        colororder(axesHandle, seriesColors);
    hold on;
        if arrayKind == "linear"
            plotReceiveGroupSize = round(sqrt(elementCount));
        else
            plotReceiveGroupSize = 1;
        end
        baseMask = resultArrayKinds == arrayKind & ...
            resultElementCounts == elementCount & ...
            resultReceiveGroupSizes == plotReceiveGroupSize & ...
            resultTransmissionCounts == plotTransmissionCount;
        scatterValues = unique(resultScatterCounts(baseMask));
        for seriesIndex = 1:numel(seriesNames)
            seriesMask = baseMask;
            if seriesIndex > 1
                seriesMask = seriesMask & resultSimulators == seriesSimulators(seriesIndex);
            end
            if ~any(seriesMask)
                continue;
            end
            if seriesIndex == 1
                measurements = resultFieldIISeconds;
            else
                measurements = resultWallSeconds;
            end
            [values, ~] = summarizeMeasurements(...
                resultScatterCounts, measurements, seriesMask, scatterValues);
            plot(scatterValues, values, ":o", ...
                "Color", seriesColors(seriesIndex, :), "LineWidth", seriesLineWidths(seriesIndex), ...
                "MarkerFaceColor", seriesColors(seriesIndex, :), ...
                "MarkerEdgeColor", seriesColors(seriesIndex, :), ...
                "MarkerSize", 7, "DisplayName", seriesNames(seriesIndex));
        end
        set(axesHandle, "XScale", "log");
        axesHandle.XTick = scatterValues;
        axesHandle.XTickLabel = arrayfun(@(value) sprintf("2^{%d}", round(log2(value))), ...
            scatterValues, "UniformOutput", false);
        axesHandle.TickLabelInterpreter = "tex";
        grid on;
        xlabel("Scatter count");
        ylabel("Mean wall time (s)");
        subtitleHandle = subtitle(sprintf("%d \\times %d elements", ...
            round(sqrt(elementCount)), round(sqrt(elementCount))));
        subtitleHandle.Color = [0.25, 0.25, 0.25];
            legendHandle = legend("Location", "northwest");
            legendHandle.Color = "w";
            legendHandle.TextColor = "k";
    end
end
sgtitle(timingFigure, hardwareLabel, "Color", "k", "FontSize", 10);
saveas(timingFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-timing.png"));
saveas(timingFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-timing.fig"));
close(timingFigure);

speedupFigure = figure("Visible", "off", "Color", "w", "Name", "Ekhos benchmark speedup");
panelIndex = 0;
for arrayKind = arrayKinds'
    elementCounts = unique(resultElementCounts(resultArrayKinds == arrayKind));
    for elementCount = elementCounts'
        panelIndex = panelIndex + 1;
        subplot(panelRows, panelColumns, panelIndex);
    axesHandle = gca;
    axesHandle.Color = "w";
    axesHandle.XColor = "k";
    axesHandle.YColor = "k";
    axesHandle.Title.Color = "k";
    axesHandle.XLabel.Color = "k";
    axesHandle.YLabel.Color = "k";
    axesHandle.GridColor = [0.7, 0.7, 0.7];
        colororder(axesHandle, seriesColors(2:end, :));
    hold on;
        if arrayKind == "linear"
            plotReceiveGroupSize = round(sqrt(elementCount));
        else
            plotReceiveGroupSize = 1;
        end
        baseMask = resultArrayKinds == arrayKind & ...
            resultElementCounts == elementCount & ...
            resultReceiveGroupSizes == plotReceiveGroupSize & ...
            resultTransmissionCounts == plotTransmissionCount;
        scatterValues = unique(resultScatterCounts(baseMask));
        for seriesIndex = 2:numel(seriesNames)
            seriesMask = baseMask & resultSimulators == seriesSimulators(seriesIndex);
            if ~any(seriesMask)
                continue;
            end
            [values, ~] = summarizeMeasurements(...
                resultScatterCounts, resultFieldIISeconds ./ resultWallSeconds, ...
                seriesMask, scatterValues);
            plot(scatterValues, values, ":o", ...
                "Color", seriesColors(seriesIndex, :), "LineWidth", seriesLineWidths(seriesIndex), ...
                "MarkerFaceColor", seriesColors(seriesIndex, :), ...
                "MarkerEdgeColor", seriesColors(seriesIndex, :), ...
                "MarkerSize", 7, "DisplayName", seriesNames(seriesIndex));
        end
        set(axesHandle, "XScale", "log");
        axesHandle.XTick = scatterValues;
        axesHandle.XTickLabel = arrayfun(@(value) sprintf("2^{%d}", round(log2(value))), ...
            scatterValues, "UniformOutput", false);
        axesHandle.TickLabelInterpreter = "tex";
        grid on;
        xlabel("Scatter count");
        ylabel("Field II / Ekhos wall-time ratio");
        subtitleHandle = subtitle(sprintf("%d \\times %d elements", ...
            round(sqrt(elementCount)), round(sqrt(elementCount))));
        subtitleHandle.Color = [0.25, 0.25, 0.25];
            legendHandle = legend("Location", "northwest");
            legendHandle.Color = "w";
            legendHandle.TextColor = "k";
    end
end
sgtitle(speedupFigure, hardwareLabel, "Color", "k", "FontSize", 10);
saveas(speedupFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-speedup.png"));
saveas(speedupFigure, fullfile(outputDirectory, "fieldII-Ekhos-benchmark-" + timestamp + "-speedup.fig"));
close(speedupFigure);
end

function [means, errors] = summarizeMeasurements(scatterCounts, measurements, mask, scatterValues)
means = nan(size(scatterValues));
errors = nan(size(scatterValues));
for scatterIndex = 1:numel(scatterValues)
    values = measurements(mask & scatterCounts == scatterValues(scatterIndex));
    if ~isempty(values)
        means(scatterIndex) = mean(values);
        errors(scatterIndex) = std(values, 0);
    end
end
end
