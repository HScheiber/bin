function Thermal_Properties_At_MP(Settings)

if ~isstruct(Settings)
    Settings = load(Settings,'-mat').Settings;
end
if ~isfield(Settings,'Verbose')
    Settings.Verbose = true;
end
% Initialize some global settings for later
[Settings.Metal,Settings.Halide] = Separate_Metal_Halide(Settings.Salt);
Settings.Longest_Cutoff = max([Settings.MDP.RList_Cutoff Settings.MDP.RCoulomb_Cutoff Settings.MDP.RVDW_Cutoff]);
[~,Settings] = MD_Batch_Template(Settings);
Settings.Finite_T_Data = Initialize_Finite_T_Data(Settings);
Settings.RefStructure = Settings.Finite_T_Data.Structure;
Settings.Structure = Settings.Finite_T_Data.Structure;

% Get rocksalt geometry and settings
WorkDir = Settings.WorkDir;
OuterDir = strrep(WorkDir,[filesep 'BestPoint_Thermal'],'');
BO_Settings = load(fullfile(OuterDir,[Settings.Salt '_' Settings.JobName '.inp']),'-mat').Model;
Full_opt_filename = fullfile(OuterDir,[Settings.Salt '_' Settings.JobName '_fullopt.mat']);
MinDat = load(Full_opt_filename,'-mat');
OptParam = MinDat.full_opt_point;

Settings.Minimization_Data = MinDat.Minimization_Data;

N = length(Settings.Minimization_Data);
Structures = cell(1,N);
for idx = 1:N
    Structures{idx} = Settings.Minimization_Data{idx}.Structure;
end

% Load bestpoint geometry
Settings.Geometry = Default_Crystal(Settings);
Settings.Geometry.a = Settings.Minimization_Data{strcmpi(Structures,Settings.RefStructure)}.a;
Settings.Geometry.b = Settings.Minimization_Data{strcmpi(Structures,Settings.RefStructure)}.b;
Settings.Geometry.c = Settings.Minimization_Data{strcmpi(Structures,Settings.RefStructure)}.c;
Settings.Ref_Density = 1/(Settings.Minimization_Data{strcmpi(Structures,Settings.RefStructure)}.V*(0.1^3)); % molecules / nm^3

% load parameters into Settings
BO_Settings = Potential_Scaling(BO_Settings,OptParam);
Settings.S = BO_Settings.S;
Settings.CRDamp = BO_Settings.CRDamp;
Settings.C6Damp = BO_Settings.C6Damp;
Settings.GAdjust_MX = BO_Settings.GAdjust_MX;
Settings.GAdjust_MM = BO_Settings.GAdjust_MM;
Settings.GAdjust_XX = BO_Settings.GAdjust_XX;

% Melting point
[~,Settings] = MD_Batch_Template(Settings);
Settings.WorkDir = fullfile(WorkDir,'Melting_Point');
Settings.BatchMode = false;
Settings.Submit_Jobs = false;
Settings.Skip_Minimization = true; % Skip the automatic geometry minimization
[Tm_estimate,~,Aborted,T_dat] = Find_Melting_Point(Settings);
Settings.Finite_T_Data.T_dat = T_dat;

if Aborted
    Settings.Finite_T_Data.MP = nan;
else
    Settings.Finite_T_Data.MP = Tm_estimate;
end

% Liquid properties
Settings.dd = [];
Settings.npme = [];
[~,Settings] = MD_Batch_Template(Settings);
Settings.WorkDir = fullfile(WorkDir,'Liq_Properties_at_MP');
Liq_Output = Calc_Liquid_Properties_at_MP(Settings);
Settings.Finite_T_Data.Liquid_V_MP = Liq_Output.Liquid_V_MP;
Settings.Finite_T_Data.Liquid_H_MP = Liq_Output.Liquid_H_MP;

% Solid properties
Settings.WorkDir = fullfile(WorkDir,'Sol_Properties_at_MP');
Sol_Output = Calc_Solid_Properties_at_MP(Settings);
Settings.Finite_T_Data.Solid_V_MP = Sol_Output.Solid_V_MP;
Settings.Finite_T_Data.Solid_H_MP = Sol_Output.Solid_H_MP;

% Combined Liquid/Solid properties
Settings.Finite_T_Data.Fusion_dH = Settings.Finite_T_Data.Liquid_H_MP - ...
    Settings.Finite_T_Data.Solid_H_MP;

Settings.Finite_T_Data.Fusion_dV = Settings.Finite_T_Data.Liquid_V_MP - ...
    Settings.Finite_T_Data.Solid_V_MP;

% Re-Save Data and output a flag
MinDat.Finite_T_Data = Settings.Finite_T_Data;
save(Full_opt_filename,'-struct','MinDat');

% Save a flag to note end of calculation
fclose(fopen(fullfile(WorkDir,'Thermal_Properties_Complete'), 'w'));
    
end