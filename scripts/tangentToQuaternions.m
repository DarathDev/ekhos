function orientations = tangentToQuaternions(tangents)
tx = tangents(1, :);
ty = tangents(2, :);
denominatorX = sqrt(1 + tx.^2);
denominatorY = sqrt(1 + ty.^2);
normalZ = sqrt(1 - (tx.^2).*(ty.^2)) ./ denominatorX ./ denominatorY;
orientations = [-tx ./ denominatorX;
                 ty ./ denominatorY;
                 zeros(size(tx));
                 1 + normalZ];
orientations = orientations ./ vecnorm(orientations, 2, 1);
end
