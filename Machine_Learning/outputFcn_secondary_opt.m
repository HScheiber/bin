function stop = outputFcn_secondary_opt(x,optimValues,state)
% outputFcn_global()
%
% OutputFun for optimizers (fminunc, fmincon etc),  saving intermediate results 
% in global variable "intermediate_data" for later access. 
%
% It is not supposed for live updates during optimization but for 
% later inspection, which is much more efficient. 
%
% Usage 
%   options = optimoptions( ... , 'OutputFcn',@outputFcn_global ); 
%   [XOpt,fval,exitflag,output] = fminunc(@fun, X0, options); 
%   intermediate_data(k).x 
%
% See also the supplied example file. 
%
% Last Changes
%   Daniel Frisch, ISAS, 10.2020: created example
%   Daniel Frisch, ISAS, 11.2019: improved documentation 
% Created
%   Daniel Frisch, ISAS, 10.2019 
%
global intermediate_data;
stop = false;
switch state
    case 'init'
        if isfile('intermediate_secondary_opt.mat') || isfile('intermediate_secondary_opt.mat.PREV')
            try
                prev_dat = load('intermediate_secondary_opt.mat');
                intermediate_data = prev_dat.intermediate_data;
                ind = length(intermediate_data)+1;
                intermediate_data(ind).x = x;
                intermediate_data(ind).optimValues = optimValues;
                intermediate_data(ind).timerVal = toc(intermediate_data(1).timerVal);
            catch
                disp('Unable to load checkpoint file, attempting to load backup.')
                if isfile('intermediate_secondary_opt.mat')
                    delete('intermediate_secondary_opt.mat');
                end
                try
                    prev_dat = load('intermediate_secondary_opt.mat.PREV','-mat');
                    intermediate_data = prev_dat.intermediate_data;
                    ind = length(intermediate_data)+1;
                    intermediate_data(ind).x = x;
                    intermediate_data(ind).optimValues = optimValues;
                    intermediate_data(ind).timerVal = toc(intermediate_data(1).timerVal);
                catch
                    disp('Unable to load backup checkpoint file, restarting.')
                    if isfile('intermediate_secondary_opt.mat.PREV')
                        delete('intermediate_secondary_opt.mat.PREV');
                    end
                    intermediate_data = struct();
                    intermediate_data.x = x;
                    intermediate_data.optimValues = optimValues;
                    intermediate_data.timerVal = tic;
                end
            end
        else
            intermediate_data = struct();
            intermediate_data.x = x;
            intermediate_data.optimValues = optimValues;
            intermediate_data.timerVal = tic;
        end
    case 'iter'
        ind = length(intermediate_data)+1;
        intermediate_data(ind).x = x;
        intermediate_data(ind).optimValues = optimValues;
        intermediate_data(ind).timerVal = toc(intermediate_data(1).timerVal);

    case 'interrupt'
        % do nothing here
    case 'done'
        % do nothing here
    otherwise
        error(['wrong switch:' state]);
end

% Backup and save to file
if isfile('intermediate_secondary_opt.mat')
    copyfile('intermediate_secondary_opt.mat','intermediate_secondary_opt.mat.PREV');
end
filename = 'intermediate_secondary_opt.mat';
save(filename,'intermediate_data');
end