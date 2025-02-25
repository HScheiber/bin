function C = suppressWarnings()
% Suppress certain warnings we never want to see while running bayesopt,
% and return an onCleanup object that restores the warning state upon
% destruction.

%   Copyright 2020 The MathWorks, Inc.

ToSuppress = {...
    'stats:classreg:learning:impl:GPImpl:GPImpl:OptimizerUnableToConverge',...
    'MATLAB:contour:ConstantData',...
    'MATLAB:contour:NonFiniteData',...
    'MATLAB:nearlySingularMatrix',...
    'MATLAB:illConditionedMatrix',...
    'MATLAB:singularMatrix',...
    'MATLAB:rankDeficientMatrix',...
};
for whichID = 1:numel(ToSuppress)
  status(whichID) = warning('off', ToSuppress{whichID});
end
C = onCleanup(@() warning(status));
end
