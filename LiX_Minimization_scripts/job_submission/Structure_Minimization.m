% Structure_Minimization
function Output = Structure_Minimization(Settings,varargin)

% Optional input settings
p = inputParser;
p.FunctionName = 'Structure_Minimization';
addOptional(p,'Continuation',[])
addOptional(p,'Extra_Properties',false,@(x)validateattributes(x,{'logical'},{'nonempty'}))
addOptional(p,'N_atoms',100,@(x)validateattributes(x,{'numeric'},{'nonempty'}))
addOptional(p,'Scratch_output_files',true,@(x)validateattributes(x,{'logical'},{'nonempty'}))
addOptional(p,'Find_Min_Params',true,@(x)validateattributes(x,{'logical'},{'nonempty'}))
addOptional(p,'Find_Similar_Params',true,@(x)validateattributes(x,{'logical'},{'nonempty'}))
parse(p,varargin{:});

Extra_Properties = p.Results.Extra_Properties; % Gathers components of energy at the end in addition to the total energy.
Scratch_output_files = p.Results.Scratch_output_files; % When true: runs calculation in a temp folder and deletes the calculation folder when finished
N_atoms = p.Results.N_atoms; % Minimum number of atoms to include in super cell
Find_Min_Params = p.Results.Find_Min_Params; % When true, finds lowest energy parameters for IC based on Data_Types. When false, uses input IC
Find_Similar_Params = p.Results.Find_Similar_Params; % When true, finds lowest energy parameters for IC if possible, but if no data is available, also looks for the same IC with non-scaled model

% Type of optimization limited to Cellopt
if Settings.MinMDP.Maintain_Symmetry
    OptTxt = 'CELLOPT';
else
    OptTxt = 'CELLOPT_SG1';
end

% Update Directory
if Scratch_output_files
    % Keep the model name short
    Model = Settings.Theory;
    WorkDir = GetMDWorkdir(Settings);
    Settings.WorkDir = fullfile([WorkDir '_OP'],Settings.Structure);
    if ~isfolder(Settings.WorkDir)
        mkdir(Settings.WorkDir)    
    end
    Settings.MinMDP.Verbose = true;
    Diary_File = fullfile(Settings.WorkDir,'Calc_Diary.log');
    diary off
    diary(Diary_File)
else
    % Use systematic name
    Model = ModelName(Settings);
    Settings.WorkDir = fullfile(Settings.project,...
        Settings.Project_Directory_Name,Settings.Salt,...
        Settings.Structure,Model,OptTxt);
    if ~isfolder(Settings.WorkDir)
        mkdir(Settings.WorkDir)    
    end
end

Output_File = fullfile(Settings.WorkDir,'Calc_Output.mat');
if isfile(Output_File)
    try
        Output = load(Output_File).Output;
        if Settings.MinMDP.Verbose
            disp([Settings.Salt ' ' Model ' ' Settings.Structure ' minimization previously completed, successfully loaded output.'])
        end
        return
    catch
        if Settings.MinMDP.Verbose
            disp('Failed to load previously completed output file, restarting calculation')
        end
        delete(Output_File);
    end
end
Input_File = fullfile(Settings.WorkDir,'Calc_Input.mat');
save(Input_File,'Settings');

if isfield(Settings,'Parallel_LiX_Minimizer') && Settings.Parallel_LiX_Minimizer
    gmx_serial = true;
elseif isfield(Settings,'Parallel_Bayesopt') && Settings.Parallel_Bayesopt
    gmx_serial = true;
elseif Settings.MinMDP.Parallel_Min
    gmx_serial = true;
else
    gmx_serial = false;
end   

% Minimum lattice bounds
switch lower(Settings.Structure)
    case 'betabeo'
        Lattice_param_LBab = 4.0; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.4; % Angstroms, lower bound on the possible lattice parameter
    case 'rocksalt'
        Lattice_param_LBab = 2.0; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.0; % Angstroms, lower bound on the possible lattice parameter
    case 'wurtzite'
        Lattice_param_LBab = 2.2; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.8; % Angstroms, lower bound on the possible lattice parameter
    case 'fivefive'
        Lattice_param_LBab = 2.2; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.8; % Angstroms, lower bound on the possible lattice parameter
    case 'sphalerite'
        Lattice_param_LBab = 2.0; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.0; % Angstroms, lower bound on the possible lattice parameter
    case 'cscl'
        Lattice_param_LBab = 2.0; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.0; % Angstroms, lower bound on the possible lattice parameter
    case {'nias' 'antinias'}
        Lattice_param_LBab = 2.2; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.8; % Angstroms, lower bound on the possible lattice parameter
    otherwise
        Lattice_param_LBab = 2.2; % Angstroms, lower bound on the possible lattice parameter
        Lattice_param_LBc = 2.2; % Angstroms, lower bound on the possible lattice parameter
end
Lattice_param_UB = 20; % Angstroms, upper bound on the possible lattice parameter
Settings.Longest_Cutoff = max([Settings.MinMDP.RList_Cutoff Settings.MinMDP.RCoulomb_Cutoff Settings.MinMDP.RVDW_Cutoff]);
Settings.Table_Length = Settings.Longest_Cutoff + 1.01; % nm. This should be at least equal rc+1 where rc is the largest cutoff

if Settings.SinglePrecision
    Settings.Table_StepSize = 0.002; % Step size of tabulated potentials in nm
else
    Settings.Table_StepSize = 0.0005; % 0.0005 Step size of tabulated potentials in nm
end

% Get default system geometry
Settings.Use_Conv_cell = Settings.MinMDP.Use_Conv_cell;
Settings.Geometry = Default_Crystal(Settings,'Scale',Settings.S);

if gmx_serial % Since using matlab parallel, make sure gromacs runs in serial
    if ~isfield(Settings,'gmx')
        [~,Settings] = MD_Batch_Template(Settings);
    end
    env.OMP_NUM_THREADS = getenv('OMP_NUM_THREADS');
    env.GMX_PME_NUM_THREADS = getenv('GMX_PME_NUM_THREADS');
    env.GMX_PME_NTHREADS = getenv('GMX_PME_NTHREADS');
    env.GMX_OPENMP_MAX_THREADS = getenv('GMX_OPENMP_MAX_THREADS');
    env.KMP_AFFINITY = getenv('KMP_AFFINITY');
    
    setenv('OMP_NUM_THREADS','1');
    setenv('GMX_PME_NUM_THREADS','1');
    setenv('GMX_PME_NTHREADS','1');
    setenv('GMX_OPENMP_MAX_THREADS','1');
    setenv('KMP_AFFINITY','disabled');
    Settings.mdrun_opts = ' -pin on -ntmpi 1 -ntomp 1';
    Settings.gmx = Settings.gmx_loc;
elseif ~Settings.Use_Conv_cell
    Settings.dd = [];
    Settings.npme = [];
    [~,Settings] = MD_Batch_Template(Settings);
end

% Find minimum lattice parameter for this
% salt/structure/model (or use initial ones)
if ~isempty(p.Results.Continuation)
    Settings.Geometry.a = p.Results.Continuation(1);
    Settings.Geometry.b = p.Results.Continuation(2);
    Settings.Geometry.c = p.Results.Continuation(3);
    AddRepWall = false;
else
    if Find_Min_Params
        [Settings,~] = FindMinLatticeParam(Settings,...
            'Find_Similar_Params',Find_Similar_Params);
    end
    switch Settings.Theory
        case {'JC' 'BD' 'BE' 'Mie' 'HS'}
            AddRepWall = false;
        otherwise
            AddRepWall = true;
    end
end

% Load topology template location
Topology_Template_file = fullfile(Settings.home,'templates','Gromacs_Templates',...
'Topology.template');

% Load Topology template
Settings.Topology_Template = fileread(Topology_Template_file);

% Add in global parameters to Topology template
Settings.Topology_Template = strrep(Settings.Topology_Template,'##GENPAIRS##',Settings.Top_gen_pairs);
Settings.Topology_Template = strrep(Settings.Topology_Template,'##FUDGELJ##',num2str(Settings.Top_fudgeLJ));
Settings.Topology_Template = strrep(Settings.Topology_Template,'##FUDGEQQ##',num2str(Settings.Top_fudgeQQ));

% Load mdp template location
MDP_Template_file = fullfile(Settings.home,'templates','Gromacs_Templates',...
'MDP.template');

% Load MDP template
Settings.MDP_Template = fileread(MDP_Template_file);

% Add in global parameters to MDP template
Settings.MDP_Template = strrep(Settings.MDP_Template,'##NSTEPS##',pad(num2str(Settings.MinMDP.nsteps_point),18));
Settings.MDP_Template = strrep(Settings.MDP_Template,'##INTEGR##',pad(Settings.MinMDP.point_integrator,18));
Settings.MDP_Template = strrep(Settings.MDP_Template,'##TIMEST##',pad(num2str(Settings.MinMDP.dt),18));

% Boolean: check if parameters can be input in without a table;
Table_Req = IsGmxTableRequired(Settings);

% Get Metal and Halide info from Current Salt
[Metal,Halide] = Separate_Metal_Halide(Settings.Salt);
if strcmp(Metal,'M')
    Metal_Info.atomic_mass = 1;
    Metal_Info.atomic_number = 1;
else
    Metal_Info = elements('Sym',Metal);
end
if strcmp(Halide,'X')
    Halide_Info.atomic_mass = 1;
    Halide_Info.atomic_number = 1;
else
    Halide_Info = elements('Sym',Halide);
end

% Insert element info into topology template
Settings.Topology_Template = strrep(Settings.Topology_Template,'##MET##',pad(Metal,2));
Settings.Topology_Template = strrep(Settings.Topology_Template,'##METZ##',pad(num2str(Metal_Info.atomic_number),3));
Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMASS##',pad(num2str(Metal_Info.atomic_mass),7));
if Settings.Polarization
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##MCHRG##',pad(num2str(Settings.S.QcoreM),2));
else
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##MCHRG##',pad(num2str(Settings.S.Q),2));
end

Settings.Topology_Template = strrep(Settings.Topology_Template,'##HAL##',pad(Halide,2));
Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALZ##',pad(num2str(Halide_Info.atomic_number),3));
Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALMASS##',pad(num2str(Halide_Info.atomic_mass),7));
if Settings.Polarization
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##XCHRG##',pad(num2str(Settings.S.QcoreX),2));
else
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##XCHRG##',pad(num2str(-Settings.S.Q),2));
end

% Select symmetry settings
if Settings.MinMDP.Maintain_Symmetry
    switch Settings.Structure
        case 'BetaBeO'
            Settings.DOF = {'a' 'c'};
            DOF_Units = {[' ' char(0197)] [' ' char(0197)]};
            
            lb = [Lattice_param_LBab Lattice_param_LBc];
            ub = repmat(Lattice_param_UB,1,2);
        case 'CsCl'
            Settings.DOF = {'a'};
            DOF_Units = {[' ' char(0197)]};
            
            lb = Lattice_param_LBab;
            ub = Lattice_param_UB;
        case 'FiveFive'
            if Settings.MinMDP.Use_Conv_cell
                Settings.DOF = {'a' 'b' 'c'};
                DOF_Units = {[' ' char(0197)] [' ' char(0197)] [' ' char(0197)]};
                
                lb = [Lattice_param_LBab Lattice_param_LBab Lattice_param_LBc];
                ub = repmat(Lattice_param_UB,1,3);
            else
                Settings.DOF = {'a' 'c'};
                DOF_Units = {[' ' char(0197)] [' ' char(0197)]};
                
                lb = [Lattice_param_LBab Lattice_param_LBc];
                ub = repmat(Lattice_param_UB,1,2);
            end
        case 'Sphalerite'
            Settings.DOF = {'a'};
            DOF_Units = {[' ' char(0197)]};
            
            lb = Lattice_param_LBab;
            ub = Lattice_param_UB;
        case {'NiAs' 'AntiNiAs'}
            Settings.DOF = {'a' 'c'};
            DOF_Units = {[' ' char(0197)] [' ' char(0197)]};
            
            lb = [Lattice_param_LBab Lattice_param_LBc];
            ub = repmat(Lattice_param_UB,1,2);
        case 'Rocksalt'
            Settings.DOF = {'a'};
            DOF_Units = {[' ' char(0197)]};
            
            lb = Lattice_param_LBab;
            ub = Lattice_param_UB;
        case 'Wurtzite'
            Settings.DOF = {'a' 'c'};
            DOF_Units = {[' ' char(0197)] [' ' char(0197)]};
            
            lb = [Lattice_param_LBab Lattice_param_LBc];
            ub = repmat(Lattice_param_UB,1,2);
    end
    DOF_txt = Settings.DOF;
else
    Settings.DOF = {'a' 'b' 'c' 'alpha' 'beta' 'gamma'};
    DOF_txt = {'a' 'b' 'c' char(945) char(946) char(947)};
    DOF_Units = {[' ' char(0197)] [' ' char(0197)] [' ' char(0197)] ...
        [' ' char(0176)] [' ' char(0176)] [' ' char(0176)]};
    
    lb = [Lattice_param_LBab Lattice_param_LBab Lattice_param_LBc 0 0 0];
    ub = [repmat(Lattice_param_UB,1,3) 180 180 180];
end

if Settings.MinMDP.Use_Conv_cell
    conv = '';
else
    switch Settings.Structure
        case {'FiveFive' 'Rocksalt' 'Sphalerite'}
            conv = '_Primitive';
        otherwise
            conv = '';
    end
end

% Extra DOF for Optimization of Fractional Coordinates in 1 step
FC_DOFs = {[Metal '_x'] [Metal '_y'] [Metal '_z'] [Halide '_x'] [Halide '_y'] [Halide '_z']};

% How many Degrees of freedom in gradient
N_DOF = length(Settings.DOF);

% Get Structure Template filename
Coordinate_File = fullfile(Settings.home,'templates',...
    [upper(Settings.MinMDP.CoordType) '_Templates'],...
    [Settings.Structure conv '.' Settings.MinMDP.CoordType]);

% Load Template text from disk
Settings.Coordinate_Template = fileread(Coordinate_File);

% Add Metal and Halide symbols
if strcmp(Settings.MinMDP.CoordType,'gro')
    Met = pad(Metal,2,'left');
    Hal = pad(Halide,2,'left');
elseif strcmp(Settings.MinMDP.CoordType,'g96')
    Met = pad(Metal,2,'right');
    Hal = pad(Halide,2,'right');
end
Settings.Coordinate_Template = strrep(Settings.Coordinate_Template,'##MET##',Met);
Settings.Coordinate_Template = strrep(Settings.Coordinate_Template,'##HAL##',Hal);

% Calculate size of supercell
Settings.N_Supercell = ceil((N_atoms/Settings.Geometry.N)^(1/3));

% Add number of unit cells to topology file
Settings.Topology_Template = strrep(Settings.Topology_Template,'##N##',num2str(Settings.N_Supercell));
Settings.Topology_Template = strrep(Settings.Topology_Template,'##GEOM##',Settings.Structure);

% Update File Base Name
Settings.FileBase = [Settings.Salt '_' Settings.Geometry.Label '_' Model '_' OptTxt];

% Update Topology and MDP files
if Settings.GaussianCharge
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##COULOMB##',pad('PME-User',18));
else
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##COULOMB##',pad('PME',18));
end
Settings.MDP_Template = strrep(Settings.MDP_Template,'##FOURIER##',pad(num2str(Settings.MinMDP.Fourier_Spacing),18));
Settings.MDP_Template = strrep(Settings.MDP_Template,'##PMEORDER##',pad(num2str(Settings.MinMDP.PME_Order),18));
Settings.MDP_Template = strrep(Settings.MDP_Template,'##EWALDTOL##',pad(num2str(Settings.MinMDP.Ewald_rtol),18));
Settings.MDP_Template = strrep(Settings.MDP_Template,'##MET##',Metal);
Settings.MDP_Template = strrep(Settings.MDP_Template,'##HAL##',Halide);

if AddRepWall
    
    if Settings.MinMDP.Verbose
        disp('Running initial minimization with added repulsive wall.')
    end
    
    % Define the function type as 1 (needed for custom functions)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##NBFUNC##','1');

    % Define the combination rules (Lorenz-berthelot)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##COMBR##','1');

    % Define all the repulsive parameters as 1.0 (already included in potentials)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETA##','1.0');
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALA##','1.0');
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALA##','1.0');
    
    TableName = [Settings.Salt '_' Model '_Table'];
    [Settings.TableFile_MX,C6,Energygrptables] = MakeTables(Settings,'MDP_Minimize',true,...
        'TableName',TableName,'Add_Wall',true);
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##ENERGYGRPSTABLE##',strjoin(Energygrptables,' '));
    
    % Dispersion coefficients
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETC##',num2str(C6.MM,'%.10e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALC##',num2str(C6.XX,'%.10e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALC##',num2str(C6.MX,'%.10e'));
    
	% Modify the MDP file
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWTYPE##',pad('user',18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWMOD##',pad('none',18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##CUTOFF##',pad('group',18));
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'ewald-rtol-lj.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'lj-pme-comb-rule.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'verlet-buffer-tolerance.+?\n','');
    
elseif Table_Req
    
    % Define the function type as 1 (needed for custom functions)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##NBFUNC##','1');
    
    % Define the combination rules (Lorenz-berthelot)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##COMBR##','1');
    
    % Define all the repulsive parameters as 1.0 (already included in potentials)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETA##','1.0');
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALA##','1.0');
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALA##','1.0');
    
    % Generate tables
    TableName = [Settings.Salt '_' Model '_Table'];
    [Settings.TableFile_MX,C6,Energygrptables] = MakeTables(Settings,'MDP_Minimize',true,...
    	'TableName',TableName);
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##ENERGYGRPSTABLE##',strjoin(Energygrptables,' '));
    
    % Dispersion coefficients
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETC##',num2str(C6.MM,'%.10e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALC##',num2str(C6.XX,'%.10e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALC##',num2str(C6.MX,'%.10e'));

    % Modify the MDP file
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWTYPE##',pad('user',18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWMOD##',pad('none',18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##CUTOFF##',pad('group',18));
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'ewald-rtol-lj.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'lj-pme-comb-rule.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'verlet-buffer-tolerance.+?\n','');
elseif strcmp(Settings.Theory,'LJ')
    Settings.TableFile_MX = '';

    % Definte the function type as 1 (LJ)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##NBFUNC##','1');

    % Define the combination rules (Lorenz-berthelot in sigma-epsilon form)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##COMBR##','2');
    
    % Add parameters to topology text
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETC##',pad(num2str(Settings.S.S.MM,'%10.8e'),10));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALC##',pad(num2str(Settings.S.S.XX,'%10.8e'),10));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALC##',pad(num2str(Settings.S.S.MX,'%10.8e'),10));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETA##',num2str(Settings.S.E.MM,'%10.8e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALA##',num2str(Settings.S.E.XX,'%10.8e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALA##',num2str(Settings.S.E.MX,'%10.8e'));
    
    % Modify the MDP file
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWTYPE##',pad(Settings.MinMDP.VDWType,18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWMOD##',pad(Settings.MinMDP.vdw_modifier,18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##CUTOFF##',pad(Settings.MinMDP.CutOffScheme,18));
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'energygrp-table.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'ewald-rtol-lj.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'lj-pme-comb-rule.+?\n','');
    
    % Add in Verlet Settings
    if strcmp(Settings.MinMDP.CutOffScheme,'Verlet')
        Settings.MDP_Template = strrep(Settings.MDP_Template,'##VerletBT##',pad(num2str(Settings.MinMDP.VerletBT),18));
    else
        Settings.MDP_Template = regexprep(Settings.MDP_Template,'verlet-buffer-tolerance.+?\n','');
    end
    
elseif contains(Settings.Theory,'JC')
    switch Settings.Theory
        case 'JC'
            Settings.WaterModel = 'SPC/E';
        case 'JC3P'
            Settings.WaterModel = 'TIP3P';
        case 'JC4P'
            Settings.WaterModel = 'TIP4PEW';
        case 'JCSD'
            Settings.WaterModel = 'SD';
    end

    Settings.TableFile_MX = '';

    % Definte the function type as 1 (LJ)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##NBFUNC##','1');

    % Define the combination rules (Lorenz-berthelot in sigma-epsilon form)
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##COMBR##','2');

    % Get JC parameters
    [MX_JC_Param,MM_JC_Param,XX_JC_Param] = JC_Potential_Parameters(Settings);
    
    % Add parameters to topology text
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETC##',pad(num2str(MM_JC_Param.sigma,'%10.8e'),10));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALC##',pad(num2str(XX_JC_Param.sigma,'%10.8e'),10));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALC##',pad(num2str(MX_JC_Param.sigma,'%10.8e'),10));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METMETA##',num2str(MM_JC_Param.epsilon,'%10.8e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##HALHALA##',num2str(XX_JC_Param.epsilon,'%10.8e'));
    Settings.Topology_Template = strrep(Settings.Topology_Template,'##METHALA##',num2str(MX_JC_Param.epsilon,'%10.8e'));
    
    % Modify the MDP file
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWTYPE##',pad(Settings.MinMDP.VDWType,18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##VDWMOD##',pad(Settings.MinMDP.vdw_modifier,18));
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##CUTOFF##',pad(Settings.MinMDP.CutOffScheme,18));
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'energygrp-table.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'ewald-rtol-lj.+?\n','');
    Settings.MDP_Template = regexprep(Settings.MDP_Template,'lj-pme-comb-rule.+?\n','');
    
    % Add in Verlet Settings
    if strcmp(Settings.MinMDP.CutOffScheme,'Verlet')
        Settings.MDP_Template = strrep(Settings.MDP_Template,'##VerletBT##',pad(num2str(Settings.MinMDP.VerletBT),18));
    else
        Settings.MDP_Template = regexprep(Settings.MDP_Template,'verlet-buffer-tolerance.+?\n','');
    end
    
else
    error(['Warning: Unknown model type: "' Settings.Theory '.'])
end

if Settings.MinMDP.Disp_Correction
    Settings.MDP_Template = [Settings.MDP_Template newline newline...
        '; Long-range dispersion correction' newline ...
        'DispCorr                 = Ener          ; apply long range dispersion corrections for Energy'];
end

if Settings.Polarization
    [Settings.Topology_Template,Settings.MDP_Template] = ...
        Polarize_Inputs(Settings,Settings.Topology_Template,Settings.MDP_Template);
else
    Settings.MDP_Template = strrep(Settings.MDP_Template,'##ENERGYGRPS##',[Met ' ' Hal]);
end

if Settings.MinMDP.Verbose
    TotalTimer = tic;
    display_option = 'iter';
    %pltfcn = 'psplotbestf';
    disp(['Beginning ' Settings.Salt ' ' Settings.Structure ' ' Model ' Optimization...'])
else
    display_option = 'none';
    %pltfcn = [];
end

rm_command = [Settings.wsl 'find ' windows2unix(Settings.WorkDir) ' -iname "#*#" ' Settings.pipe ' xargs rm -f'];

%% Begin Optimization
% Loop broken when convergence criteria is met or max cycles reached
[~,~] = system(rm_command);

x0 = zeros(1,N_DOF);
h = zeros(1,N_DOF);

% Load initial conditions
for idx = 1:N_DOF
    x0(idx) = Settings.Geometry.(Settings.DOF{idx});
    h(idx) = nuderst(Settings.Geometry.(Settings.DOF{idx}))*1e-2;
end

fun = @(x)Calculate_Crystal_Energy(x,Settings);
conv_fun = @(x,optimValues,state)check_conv(x,optimValues,state,...
    Settings.MinMDP.E_Unphys);

if strcmp(Settings.Theory,'HS')
%        Use a gradient-free approach for HS model due to the discontinuity
    optionsNM = optimset('Display',display_option,'MaxIter',Settings.MinMDP.MaxCycles,...
        'TolFun',1e-6,'TolX',1e-6,'MaxFunEvals',Inf);

    [lattice_params,E] = fminsearch(fun,x0,optionsNM);
    Gradient = nan;
    calc_failed = false;
else
    options = optimoptions(@fmincon,'Display',display_option,'Algorithm','active-set',...
        'DiffMaxChange',1e-3,'OptimalityTolerance',Settings.MinMDP.Gradient_Tol_Max,...
        'OutputFcn',conv_fun,'ObjectiveLimit',Settings.MinMDP.E_Unphys,...
        'UseParallel',Settings.MinMDP.Parallel_Min,'MaxIterations',Settings.MinMDP.MaxCycles,...
        'FiniteDifferenceStepSize',h,'StepTolerance',1e-6,'FunctionTolerance',1e-6,...
        'FiniteDifferenceType','forward','MaxFunctionEvaluations',100,...
        'RelLineSrchBnd',1);
    
    try
        [lattice_params,E,exitflag,~,~,Gradient,~] = fmincon(fun,x0,[],[],[],[],lb,ub,[],options);
    catch
        options = optimoptions(@fmincon,'Display',display_option,'Algorithm','active-set',...
            'DiffMaxChange',1e-3,'OptimalityTolerance',Settings.MinMDP.Gradient_Tol_Max,...
            'OutputFcn',conv_fun,'ObjectiveLimit',Settings.MinMDP.E_Unphys,...
            'UseParallel',Settings.MinMDP.Parallel_Min,'MaxIterations',Settings.MinMDP.MaxCycles,...
            'FiniteDifferenceStepSize',h,'StepTolerance',1e-6,'FunctionTolerance',1e-6,...
            'FiniteDifferenceType','forward','MaxFunctionEvaluations',200);
        [lattice_params,E,exitflag,~,~,Gradient,~] = fmincon(fun,x0,[],[],[],[],lb,ub,[],options);
    end
    
    % Failed to produce a reasonable answer
    if any(exitflag == -2) || ...
            any( abs(lattice_params - lb) < sqrt(eps) ) || ...
            any( abs(lattice_params - ub) < sqrt(eps) ) || ...
            E < Settings.MinMDP.E_Unphys
        calc_failed = true;
    else
        calc_failed = false;
    end
end

for idx = 1:N_DOF
    Settings.Geometry.(Settings.DOF{idx}) = lattice_params(idx);
end
if Settings.MinMDP.Maintain_Symmetry
    [Settings.Geometry] = SymmetryAdapt(Settings.Geometry,Settings.Structure);
end

% Restart the calculation from the fixed point without the added wall to ensure the energy is correct
% if AddRepWall
%     if Settings.MinMDP.Verbose
%         disp('Rerunning minimization without additional repulsive wall.')
%     end
%     % Restore env variables
%     setenv('OMP_NUM_THREADS',env.OMP_NUM_THREADS);
%     setenv('GMX_PME_NUM_THREADS',env.GMX_PME_NUM_THREADS);
%     setenv('GMX_PME_NTHREADS',env.GMX_PME_NTHREADS);
%     setenv('GMX_OPENMP_MAX_THREADS',env.GMX_OPENMP_MAX_THREADS);
%     setenv('KMP_AFFINITY',env.KMP_AFFINITY);
%     
%     abc = [Settings.Geometry.a Settings.Geometry.b Settings.Geometry.c];
%     Output = Structure_Minimization(Settings,'Continuation',abc,...
%         'Extra_Properties',Extra_Properties,'N_atoms',N_atoms);
%     return
% end

% Uses an additional energy calculation to grab things like the coulomb metal-metal
% component of the total energy, the lenndard-jones energy, etc
if Extra_Properties
    OptimizationLoop(Settings,'Extra_Properties',Extra_Properties);

    Output = GrabEnergy(Settings.WorkDir,Settings.FileBase,...
        'Extra_Properties',Extra_Properties);
    
    totatoms_info = dir(fullfile(Settings.WorkDir,...
        [Settings.FileBase '.mat']));
    Atoms_file = fullfile(Settings.WorkDir,totatoms_info.name);

    % Open the mat file to get total number of atoms/molecules
    N_info = load(Atoms_file,'-mat','N_Cell','N_total');
    Output.N_atoms = N_info.N_total;
end

% Record properties of calculation into object object
if Settings.MinMDP.Use_Conv_cell
    Output.a = Settings.Geometry.a;
    Output.b = Settings.Geometry.b;
    Output.c = Settings.Geometry.c;
    Output.FC_Metal = Settings.Geometry.FC_Metal;
    Output.FC_Halide = Settings.Geometry.FC_Halide;
else
    % Transform back to conventional cell
    switch Settings.Structure
        case 'Rocksalt'
            Output.a = Settings.Geometry.a*sqrt(2);
            Output.b = Settings.Geometry.b*sqrt(2);
            Output.c = Settings.Geometry.c*sqrt(2);
        case 'Sphalerite'
            Output.a = Settings.Geometry.a*sqrt(2);
            Output.b = Settings.Geometry.b*sqrt(2);
            Output.c = Settings.Geometry.c*sqrt(2);
        case 'FiveFive'
            Output.a = Settings.Geometry.c;
            Output.b = (3/sqrt(3))*Settings.Geometry.a;
            Output.c = Settings.Geometry.b;
        otherwise
            Output.a = Settings.Geometry.a;
            Output.b = Settings.Geometry.b;
            Output.c = Settings.Geometry.c;
    end
    
    Settings.Use_Conv_cell = true;
    Def_Crystal = Default_Crystal(Settings);
    Output.FC_Metal = Def_Crystal.FC_Metal;
    Output.FC_Halide = Def_Crystal.FC_Halide;
end

% Calculate volume in Ang^3/Formula unit based on the current unit cell
% (may be conventional or primitive)
TM = Settings.Geometry.Transform.*[Settings.Geometry.a; Settings.Geometry.b; Settings.Geometry.c];
a_vec = TM(1,:);
b_vec = TM(2,:);
c_vec = TM(3,:);
Output.V = (dot(cross(a_vec,b_vec),c_vec))/(Settings.Geometry.N/2);
Output.E = E;
Output.Salt = Settings.Salt;
Output.Structure = Settings.Structure;
Output.Model = Settings.Theory;
Output.CalcFail = calc_failed;

if Settings.MinMDP.Verbose
    Settings.Geometry.a = Output.a;
    Settings.Geometry.b = Output.b;
    Settings.Geometry.c = Output.c;
    Telap = datestr(seconds(toc(TotalTimer)),'HH:MM:SS');
    disp(['Completed: ' Settings.Salt ' ' Settings.Structure ' ' Model ' Geometry Optimization. Time ' Telap])
    disp(['Final Optimized Energy is ' num2str(E,'%4.10f') ' kJ/mol'])
    for Didx = 1:N_DOF
        if ~ismember(Settings.DOF{Didx},FC_DOFs)
            disp(['Lattice Parameter ' DOF_txt{Didx} ' = ' ...
                num2str(Settings.Geometry.(Settings.DOF{Didx}),'%2.8f') DOF_Units{Didx} '.']);
        end
    end
    disp(['Fractional Coordinates for ' Metal ': ']);
    disp(num2str(Settings.Geometry.FC_Metal(:,:),'%2.8f '))
    disp(['Fractional Coordinates for ' Halide ': ']);
    disp(num2str(Settings.Geometry.FC_Halide(:,:),'%2.8f '))
    disp('Components of Final Gradient:')
    disp(num2str(Gradient','%5.4E  '))
end

% Clean up the calculation directory
if Scratch_output_files
    % Get a list of all files in this folder.
    files = dir(Settings.WorkDir);
    dirFlags = [files.isdir];
    subFolders = files(dirFlags);
    subFolders = subFolders(3:end); % exclude . and ..
    subFiles = files(~dirFlags);
    for idx = 1:length(subFolders)
        try
            rmdir(fullfile(subFolders(idx).folder,subFolders(idx).name),'s');
        catch
            continue
        end
    end
    for idx = 1:length(subFiles)
        switch subFiles(idx).name
            case {'Calc_Input.mat' 'Calc_Diary.log' 'Calc_Output.mat'}
                continue
            otherwise
                try
                    delete(fullfile(subFiles(idx).folder,subFiles(idx).name));
                catch
                    continue
                end
        end
    end
    save(Output_File,'Output');
    diary off
    if isfield(Settings,'Diary_Loc') && ~isempty(Settings.Diary_Loc)
        diary(Settings.Diary_Loc)
    end
end

% Return environmental variables back if changed, turn off parallel pool
if gmx_serial
    setenv('OMP_NUM_THREADS',env.OMP_NUM_THREADS);
    setenv('GMX_PME_NUM_THREADS',env.GMX_PME_NUM_THREADS);
    setenv('GMX_PME_NTHREADS',env.GMX_PME_NTHREADS);
    setenv('GMX_OPENMP_MAX_THREADS',env.GMX_OPENMP_MAX_THREADS);
    setenv('KMP_AFFINITY',env.KMP_AFFINITY);
end

end