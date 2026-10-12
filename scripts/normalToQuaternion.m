function orientations = normalToQuaternion(normals)
% Convert local +Z normals to [x; y; z; w] orientations.
normals = single(normals);
normals = normals ./ vecnorm(normals, 2, 1);
count = size(normals, 2);
orientations = zeros(4, count, 'single');
regular = normals(3, :) > -1 + 1e-6;
orientations(1, regular) = -normals(2, regular);
orientations(2, regular) = normals(1, regular);
orientations(4, regular) = 1 + normals(3, regular);
orientations(1, ~regular) = 1;
orientations = orientations ./ vecnorm(orientations, 2, 1);
end
