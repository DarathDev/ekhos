function [elements, transmissions, receiveChannels] = sequenceToElementSets(array, biasPattern, transmitApodization, transmitDelays, receiveApodizations)

arguments
	array(1,1) tobe.RowColumnArray
	biasPattern(:, :) single
	transmitApodization(:, :) single
	transmitDelays(:, :) single
	receiveApodizations(:, :) single
end

rowCount = double(array.ElementCount(1));
columnCount = double(array.ElementCount(2));
elementCount = rowCount * columnCount;
rowElements = array.GetElements("Rows");
columnElements = array.GetElements("Columns");
eventCount = size(biasPattern, 1);

lineCount = rowCount + columnCount;
assert(size(biasPattern, 2) == lineCount, ...
	"biasPattern must contain one value for every row and column element.");
assert(isequal(size(transmitApodization), size(biasPattern)), ...
	"transmitApodization must have the same size as biasPattern.");
assert(isequal(size(transmitDelays), size(biasPattern)), ...
	"transmitDelays must have the same size as biasPattern.");
assert(isequal(size(receiveApodizations), size(biasPattern)), ...
	"receiveApodizations must have the same size as biasPattern.");

elementWidth = array.GetWidth();
[xGrid, yGrid] = array.GetElementPositionMatrix();

elements = ekhos.RectangularElementSet();
elements.Count = uint32(elementCount);
elements.Positions = single([
	reshape(xGrid, 1, []);
	reshape(yGrid, 1, []);
	zeros(1, elementCount)
	]);
elements.Orientations = repmat(single([0; 0; 0; 1]), 1, elementCount);
elements.Sizes = repmat(single(elementWidth([2, 1]).'), 1, elementCount);
elements.Apodizations = ones(1, elementCount, 'single');
elements.Delays = zeros(1, elementCount, 'single');

transmissions = createArray(1, eventCount, "ekhos.TransmissionSet");
receiveChannels = createArray(1, eventCount, "ekhos.ReceiveChannelSet");

lineIndices = reshape(1:elementCount, columnCount, rowCount).';
for eventIndex = 1:eventCount
	biasApodization = biasPattern(eventIndex, rowElements).'-biasPattern(eventIndex, columnElements);
	transmitApodizationGrid = transmitApodization(eventIndex, rowElements)' ...
		+ transmitApodization(eventIndex, columnElements);
	transmissionApodization = biasApodization .* transmitApodizationGrid;

	transmissionDelay = (transmitDelays(eventIndex, rowElements) .* single(transmitApodization(eventIndex, rowElements) ~= 0))' ...
		+ (transmitDelays(eventIndex, columnElements) .* single(transmitApodization(eventIndex, columnElements) ~= 0));

	transmissions(eventIndex).Count = uint32(1);
	transmissions(eventIndex).ElementCounts = uint32(elementCount);
	transmissions(eventIndex).Indices = int32(1:elementCount);
	transmissions(eventIndex).Apodizations = reshape(transmissionApodization.', 1, []);
	transmissions(eventIndex).Delays = reshape(transmissionDelay.', 1, []);
	transmissions(eventIndex).Impulse = uint16(1);
	transmissions(eventIndex).Excitation = uint16(1);

	hasRowReceive = any(receiveApodizations(eventIndex, rowElements) ~= 0);
	hasColumnReceive = any(receiveApodizations(eventIndex, columnElements) ~= 0);
	receiveLineCount = hasRowReceive * rowCount + hasColumnReceive * columnCount;
	receiveElementCount = (hasRowReceive + hasColumnReceive) * elementCount;
	receiveChannels(eventIndex).Count = uint32(receiveLineCount);
	receiveChannels(eventIndex).ElementCounts = zeros(1, receiveLineCount, 'uint32');
	receiveChannels(eventIndex).Indices = zeros(1, receiveElementCount, 'int32');
	receiveChannels(eventIndex).Apodizations = zeros(1, receiveElementCount, 'single');
	receiveChannels(eventIndex).Delays = zeros(1, receiveElementCount, 'single');
	receiveChannels(eventIndex).Impulse = ones(1, receiveLineCount, 'uint16');
	channelIndex = 1;
	elementOffset = 0;
	if hasRowReceive
		for rowIndex = rowElements
			receiveChannels(eventIndex).ElementCounts(channelIndex) = uint32(columnCount);
			receiveChannels(eventIndex).Indices(elementOffset + (1:columnCount)) = int32(lineIndices(rowIndex, :));
			receiveChannels(eventIndex).Apodizations(elementOffset + (1:columnCount)) = ...
				biasApodization(rowIndex, :) * receiveApodizations(eventIndex, rowIndex);
			elementOffset = elementOffset + columnCount;
			channelIndex = channelIndex + 1;
		end
	end
	if hasColumnReceive
		for columnIndex = 1:columnCount
			receiveChannels(eventIndex).ElementCounts(channelIndex) = uint32(rowCount);
			receiveChannels(eventIndex).Indices(elementOffset + (rowElements)) = int32(lineIndices(:, columnIndex));
			receiveChannels(eventIndex).Apodizations(elementOffset + (rowElements)) = ...
				biasApodization(:, columnIndex).' * receiveApodizations(eventIndex, rowCount + columnIndex);
			elementOffset = elementOffset + rowCount;
			channelIndex = channelIndex + 1;
		end
	end
end
end
