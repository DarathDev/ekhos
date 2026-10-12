function elements = fieldIIArrayToEkhosArray(aperture, apodizations, delays)
arguments
    aperture
    apodizations = []
    delays = []
end

rectData = fieldII.xdc_get(aperture, 'rect');
elementCount = size(rectData, 2);
if isempty(apodizations)
    apodizations = ones(1, elementCount, 'single');
else
    apodizations = single(reshape(apodizations, 1, []));
    assert(numel(apodizations) == elementCount, ...
        'apodizations must contain one value per Field II rectangle.');
end
if isempty(delays)
    delays = zeros(1, elementCount, 'single');
else
    delays = single(reshape(delays, 1, []));
    assert(numel(delays) == elementCount, ...
        'delays must contain one value per Field II rectangle.');
end

positions = single(rectData(8:10, :));
sizes = single(rectData(3:4, :));
orientations = zeros(4, elementCount, 'single');
for elementIndex = 1:elementCount
    corners = reshape(rectData(11:22, elementIndex), 4, 3)';
    widthAxis = corners(:, 4) - corners(:, 1);
    heightAxis = corners(:, 2) - corners(:, 1);
    normal = cross(widthAxis, heightAxis);
    frame = [widthAxis / norm(widthAxis), heightAxis / norm(heightAxis), normal / norm(normal)];
    orientations(:, elementIndex) = rotationMatrixToQuaternion(frame);
end

elements = ekhos.RectangularElementSet();
elements.Count = uint32(elementCount);
elements.Positions = positions;
elements.Orientations = orientations;
elements.Sizes = sizes;
elements.Apodizations = apodizations;
elements.Delays = delays;
end
