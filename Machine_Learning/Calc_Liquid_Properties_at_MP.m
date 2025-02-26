function Output = Calc_Liquid_Properties_at_MP(Settings)

    %% What this function does:
    % Initialize density based on experiment
    % Create a cubic box with the smallest possible system size for a given cutoff
    % Increase that box size by Settings.Cutoff_Buffer to account for possibility of shrinkage
    % Randomly fill box with appropriate number of atoms to reach experimental density
    % Use Make_Tables function if necessary, run a brief ~500 step minimization
    % Run NPT simulation for [Settings.Liquid_Test_Time] amount of time using fast equilibration settings (Berendsen baro and Velocity-Rescale thermo)
    % Calculate average density of equilibrated box based on last 25% of simulation
    % Give new density as output
    
    Inp_Settings = Settings;
    
    if ~isfield(Settings,'WorkDir')
        Settings.WorkDir = GetMDWorkdir(Settings);
        Settings.WorkDir = [Settings.WorkDir '_LP'];
    end
    if ~isfolder(Settings.WorkDir)
        mkdir(Settings.WorkDir)
    end
    
    diary off
    diary(fullfile(Settings.WorkDir,'Calculation_diary.log'))
    
    Output_File = fullfile(Settings.WorkDir,'Calc_Output.mat');
    if isfile(Output_File)
        try
            Output = load(Output_File).Output;
            diary off
            return
        catch
            if Settings.Verbose
                disp('Failed to load previously completed output, restarting calculation')
            end
            delete(Output_File);
        end
    end
    % Save calculation settings
    Input_File = fullfile(Settings.WorkDir,'Calc_Settings.mat');
    save(Input_File,'Settings')
    
    Settings = Update_MD_Settings(Settings);
    
    % Check for previous minimization calculation    
    Minimization_TRR_File = fullfile(Settings.WorkDir,'Prep_Liq.trr'); % mMinimizaion started
    Minimized_Geom_File = fullfile(Settings.WorkDir,['Equil_Liq.' Settings.CoordType]); % Minimization complete
    
    Run_Minimization = true;
    if isfile(Minimized_Geom_File)
        try
            % Check integrity of minimized geom file
            Data = load_gro_file(Minimized_Geom_File);
            if Data.N_atoms >= Settings.N_atoms
                % Check to ensure minimization completed
                gmx_check = [Settings.gmx_loc Settings.g_check ' -f ' windows2unix(Minimization_TRR_File)];
                [state,outp] = system(gmx_check);
                lf = regexp(outp,'Last frame.+time *([0-9]|\.)+','tokens','once');
                if state == 0 && ~isempty(lf)
                    last_frame = str2double(lf{1});
                    if last_frame >= Settings.MinMDP.nsteps_min
                        Run_Minimization = false;
                    end
                end
            end
        catch
            Run_Minimization = true;
        end
    end
        
	if Run_Minimization
        % Grab reference density, cutoff, and corresponding box size
        L = (2*Settings.Longest_Cutoff)*Settings.Cutoff_Buffer; % nm, the box dimension
        Volume = L^3; % Volume in nm^3
        nmol_liquid = round(Volume*Settings.Ref_Density*Settings.ScaleInitialLiqDensity);
        
        if nmol_liquid < Settings.N_atoms/2 % Enforce a minimum of [Settings.N_atoms] atoms
            nmol_liquid = Settings.N_atoms/2;
            Volume = nmol_liquid/(Settings.Ref_Density*Settings.ScaleInitialLiqDensity);
            L = Volume^(1/3);
        end
        
        R0 = num2str(min(0.5*((3/(4*pi))*(Volume/nmol_liquid))^(1/3),0.57),'%0.3f');
        
        % Initialize empty cubic box
        Box.a_vec  = [L 0 0];
        Box.b_vec  = [0 L 0];
        Box.c_vec  = [0 0 L];
        Box.boxcoords = {L L L 0 0 0 0 0 0};
        Box.Volume = Volume;
        Box.Salt = Settings.Salt;
        Box.N = 0;
        Box.N_atoms = 0;
        Box.comment = [Settings.Salt ' liquid cell'];
        Box.res_number = double.empty(0,1);
        Box.res_name = cell.empty(0,1);
        Box.atom_name = cell.empty(0,1);
        Box.atom_number = int32.empty(0,1);
        Box.xyz = double.empty(0,3);
        Box.vel = double.empty(0,3);
        
        % Save empty box
        Liq_Box_File = fullfile(Settings.WorkDir,['Prep_Liq.' Settings.CoordType]);
        SaveGroFile(Liq_Box_File,Box,true);
        
        Ref_M = fullfile(Settings.home,'templates','GRO_Templates',[Settings.Metal '_Box.gro']);
        Ref_X = fullfile(Settings.home,'templates','GRO_Templates',[Settings.Halide '_Box.gro']);
        
        % Add metal
        if Settings.Verbose
            disp(['Randomly adding ' num2str(nmol_liquid) ' ' Settings.Metal ' ions to liquid box...'])
        end
        mtimer = tic;
        Prep_Liq_Metal_Only = fullfile(Settings.WorkDir,['Prep_Liq_Metal_Only.' Settings.CoordType]);
        cmd = [Settings.gmx_loc Settings.insert_molecules ' -f ' windows2unix(Liq_Box_File) ' -ci ' windows2unix(Ref_M) ...
            ' -o ' windows2unix(Prep_Liq_Metal_Only) ' -nmol ' num2str(nmol_liquid) ' -try 200 -scale ' R0 ' -radius ' R0];
        [errcode,output] = system(cmd);
        
        if errcode ~= 0
            disp(output);
            error(['Error adding ' Settings.Metal ' atoms with insert-molecules. Problem command: ' newline cmd]);
        end
        if Settings.Verbose
            disp([Settings.Metal ' atoms added. Epalsed Time: ' datestr(seconds(toc(mtimer)),'HH:MM:SS')])
        end
        
        % Add Halide
        Prep_Liq_Random_Liq = fullfile(Settings.WorkDir,['Prep_Liq_Random_Liq.' Settings.CoordType]);
        if Settings.Verbose
            disp(['Randomly adding ' num2str(nmol_liquid) ' ' Settings.Halide ' ions to liquid box...'])
        end
        htimer = tic;
        cmd = [Settings.gmx_loc Settings.insert_molecules ' -ci ' windows2unix(Ref_X) ' -f ' windows2unix(Prep_Liq_Metal_Only) ...
            ' -o ' windows2unix(Prep_Liq_Random_Liq) ' -nmol ' num2str(nmol_liquid) ' -try 400 -scale ' R0 ' -radius ' R0];
        
        [errcode,output] = system(cmd);
        
        if errcode ~= 0
            disp(output);
            error(['Error adding ' Settings.Halide ' atoms with insert-molecules. Problem command: ' newline cmd]);
        end
        if Settings.Verbose
            disp([Settings.Halide ' atoms added. Epalsed Time: ' datestr(seconds(toc(htimer)),'HH:MM:SS')])
        end
        
        % Load current randomly-generated liquid file data
        Random_Liquid_data = load_gro_file(Prep_Liq_Random_Liq);
        
        % Check to make sure all atoms were added
        if Random_Liquid_data.N_atoms ~= nmol_liquid*2
            error('Not all requested liquid atoms were added!')
        end
        
        % If model is polarizable, add in shell positions
        Settings.FileBase = 'Prep_Liq';
        ndx_add = add_polarization_shells(Settings,Prep_Liq_Random_Liq);
        
        %% Minimize the randomly-generated liquid: build MDP file
        MDP = Settings.MDP;
        MDP.Minimization_txt = fileread(fullfile(Settings.home,'templates','Gromacs_Templates',...
        'MDP.template'));
        
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##NSTEPS##',pad(num2str(Settings.MinMDP.nsteps_min),18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##INTEGR##',pad(Settings.MinMDP.min_integrator,18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'dt                       = ##TIMEST##; Time step (ps)',...
            ['emtol                    = ' num2str(Settings.MinMDP.emtol)]);
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##MET##',Settings.Metal);
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##HAL##',Settings.Halide);
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##COULOMB##',pad(num2str(MDP.CoulombType),18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##FOURIER##',pad(num2str(MDP.Fourier_Spacing),18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##PMEORDER##',pad(num2str(MDP.PME_Order),18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##EWALDTOL##',pad(num2str(MDP.Ewald_rtol),18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##RLIST##',pad(num2str(MDP.RList_Cutoff),18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##RCOULOMB##',pad(num2str(MDP.RCoulomb_Cutoff),18));
        MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##RVDW##',pad(num2str(MDP.RVDW_Cutoff),18));
        
        Table_Req = IsGmxTableRequired(Settings);
        Settings.JobName = [Settings.Theory '_TestModel'];
        
        if Table_Req
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##VDWTYPE##',pad('user',18));
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##VDWMOD##',pad(MDP.vdw_modifier,18));
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##CUTOFF##',pad('group',18));
            MDP.Minimization_txt = regexprep(MDP.Minimization_txt,'ewald-rtol-lj.+?\n','');
            MDP.Minimization_txt = regexprep(MDP.Minimization_txt,'lj-pme-comb-rule.+?\n','');
            MDP.Minimization_txt = regexprep(MDP.Minimization_txt,'verlet-buffer-tolerance.+?\n','');
            
            % For minimization, add in a close-range repulsive wall to the potential with the following function
            [Settings.TableFile_MX,C6,Energygrptables] = MakeTables(Settings,'MDP_Minimize',true,...
                'TableName',[Settings.JobName '_Table'],'Add_Wall',true);
            
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##ENERGYGRPSTABLE##',strjoin(Energygrptables,' '));
        else
            % Modify the MDP file
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##VDWTYPE##',pad(MDP.VDWType,18));
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##VDWMOD##',pad(MDP.vdw_modifier,18));
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##CUTOFF##',pad(MDP.CutOffScheme,18));
            
            MDP.Minimization_txt = regexprep(MDP.Minimization_txt,'energygrp-table.+?\n','');
            MDP.Minimization_txt = regexprep(MDP.Minimization_txt,'ewald-rtol-lj.+?\n','');
            MDP.Minimization_txt = regexprep(MDP.Minimization_txt,'lj-pme-comb-rule.+?\n','');
            
            % Add in Verlet Settings
            if strcmp(MDP.CutOffScheme,'Verlet')
                MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##VerletBT##',pad(num2str(MDP.VerletBT),18));
            else
                MDP.Minimization_txt = regexprep(MDP.Minimization_txt,'verlet-buffer-tolerance.+?\n','');
            end
            Settings.TableFile_MX = '';
        end
        
        % Add in dispersion corrections
        if Settings.MDP.Disp_Correction
            MDP.Minimization_txt = [MDP.Minimization_txt newline newline...
                '; Long-range dispersion correction' newline ...
                'DispCorr                 = EnerPres          ; apply long range dispersion corrections for Energy and pressure'];
        end
        
        % Create a topology file for the liquid box to be minimized
        % Load topology template location
        Topology_Template_file = fullfile(Settings.home,'templates','Gromacs_Templates',...
        'Topology.template');
        
        % Load Topology template
        Settings.Topology_Text = fileread(Topology_Template_file);
        
        % Add in global parameters to Topology template
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##GENPAIRS##',Settings.Top_gen_pairs);
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##FUDGELJ##',num2str(Settings.Top_fudgeLJ));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##FUDGEQQ##',num2str(Settings.Top_fudgeQQ));
        
        Metal_Info = elements('Sym',Settings.Metal);
        Halide_Info = elements('Sym',Settings.Halide);
        
        % Insert element info into topology template
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##MET##',pad(Settings.Metal,2));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METZ##',pad(num2str(Metal_Info.atomic_number),3));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMASS##',pad(num2str(Metal_Info.atomic_mass),7));
        if Settings.Polarization
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##MCHRG##',pad(num2str(Settings.S.QcoreM),2));
        else
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##MCHRG##',pad(num2str(Settings.S.Q),2));
        end
        
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##HAL##',pad(Settings.Halide,2));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALZ##',pad(num2str(Halide_Info.atomic_number),3));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALMASS##',pad(num2str(Halide_Info.atomic_mass),7));
        if Settings.Polarization
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##XCHRG##',pad(num2str(Settings.S.QcoreX),2));
        else
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##XCHRG##',pad(num2str(-Settings.S.Q),2));
        end
        
        % Add number of unit cells to topology file
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##N##x##N##x##N##',num2str(nmol_liquid));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##GEOM##','molecule liquid');
        
        if Table_Req
            % Define the function type as 1 (needed for tabulated functions)
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##NBFUNC##','1');
            
            % Define the combination rules (Lorenz-berthelot)
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##COMBR##','1');
            
            % Define the repulsive parameters as 1.0 (already included in potentials)
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETA##','1.0');
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALA##','1.0');
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALA##','1.0');
            
            % Dispersion coefficients
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETC##',num2str(C6.MM,'%.10e'));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALC##',num2str(C6.XX,'%.10e'));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALC##',num2str(C6.MX,'%.10e'));
        elseif strcmp(Settings.Theory,'LJ')
            
            % Definte the function type as 1 (LJ)
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##NBFUNC##','1');
            
            % Define the combination rules (Lorenz-berthelot in sigma-epsilon form)
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##COMBR##','2');
            
            % Add parameters to topology text
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETC##',pad(num2str(Settings.S.S.MM,'%10.8e'),10));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALC##',pad(num2str(Settings.S.S.XX,'%10.8e'),10));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALC##',pad(num2str(Settings.S.S.MX,'%10.8e'),10));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETA##',num2str(Settings.S.E.MM,'%10.8e'));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALA##',num2str(Settings.S.E.XX,'%10.8e'));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALA##',num2str(Settings.S.E.MX,'%10.8e'));

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
            
            % Definte the function type as 1 (LJ)
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##NBFUNC##','1');
            
            % Define the combination rules (Lorenz-berthelot in sigma-epsilon form)
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##COMBR##','2');
            
            % Get JC parameters
            [MX_JC_Param,MM_JC_Param,XX_JC_Param] = JC_Potential_Parameters(Settings);
            
            % Add parameters to topology text
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETC##',pad(num2str(MM_JC_Param.sigma,'%10.8e'),10));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALC##',pad(num2str(XX_JC_Param.sigma,'%10.8e'),10));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALC##',pad(num2str(MX_JC_Param.sigma,'%10.8e'),10));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETA##',num2str(MM_JC_Param.epsilon,'%10.8e'));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALA##',num2str(XX_JC_Param.epsilon,'%10.8e'));
            Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALA##',num2str(MX_JC_Param.epsilon,'%10.8e'));
        else
            error(['Unknown model type: "' Settings.Theory '.'])
        end
        
        % Add in the atom list
        Atomlist = copy_atom_order(Prep_Liq_Random_Liq);
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##LATOMS##',Atomlist);
        Top_Filename = fullfile(Settings.WorkDir,'Prep_Liq.top');
        
        if Settings.Polarization
            [Settings.Topology_Text,MDP.Minimization_txt] = ...
                Polarize_Inputs(Settings,Settings.Topology_Text,MDP.Minimization_txt);
        else
            MDP.Minimization_txt = strrep(MDP.Minimization_txt,'##ENERGYGRPS##',[Settings.Metal ' ' Settings.Halide]);
        end
        
        % Save MDP file
        MDP_Filename = fullfile(Settings.WorkDir,'Prep_Liq.mdp');
        fidMDP = fopen(MDP_Filename,'wt');
        fwrite(fidMDP,regexprep(MDP.Minimization_txt,'\r',''));
        fclose(fidMDP);
        
        % Save topology file
        fidTOP = fopen(Top_Filename,'wt');
        fwrite(fidTOP,regexprep(Settings.Topology_Text,'\r',''));
        fclose(fidTOP);
        
        TPR_File = fullfile(Settings.WorkDir,'Prep_Liq.tpr');
        MDPout_File = fullfile(Settings.WorkDir,'Prep_Liq_out.mdp');
        GrompLog_File = fullfile(Settings.WorkDir,'Prep_Liq_Grompplog.log');
        
        FMin_Grompp = [Settings.gmx_loc Settings.grompp ' -c ' windows2unix(Prep_Liq_Random_Liq) ...
            ' -f ' windows2unix(MDP_Filename) ' -p ' windows2unix(Top_Filename) ...
            ' -o ' windows2unix(TPR_File) ' -po ' windows2unix(MDPout_File) ...
            ndx_add ' -maxwarn ' num2str(Settings.MaxWarn) ...
            Settings.passlog windows2unix(GrompLog_File)];
        [state,~] = system(FMin_Grompp);
        % Catch error in grompp
        if state ~= 0
            error(['Error running GROMPP. Problem command: ' newline FMin_Grompp]);
        else
            delete(GrompLog_File)
        end
        
        % Prepare minimization mdrun command
        Log_File = fullfile(Settings.WorkDir,'Prep_Liq.log');
        Energy_file = fullfile(Settings.WorkDir,'Prep_Liq.edr');
        
        mdrun_command = [Settings.gmx Settings.mdrun ' -s ' windows2unix(TPR_File) ...
            ' -o ' windows2unix(Minimization_TRR_File) ' -g ' windows2unix(Log_File) ...
            ' -e ' windows2unix(Energy_file) ' -c ' windows2unix(Minimized_Geom_File) ...
            ' -deffnm ' windows2unix(fullfile(Settings.WorkDir,'Prep_Liq')) ...
            Settings.mdrun_opts];
        
        if Table_Req
            mdrun_command = [mdrun_command ' -table ' windows2unix(Settings.TableFile_MX)];
        end
        
        % Liquid Minimization
        if Settings.Verbose
            disp('Begining Liquid Minimization...')
        end
        mintimer = tic;
        [state,~] = system(mdrun_command);
        if state == 0
            if Settings.Verbose
                disp(['System Successfully Minimized! Epalsed Time: ' datestr(seconds(toc(mintimer)),'HH:MM:SS')]);
            end
        else
            if Settings.Verbose
                disp('Failed to minimize, retrying with fewer MPI ranks.')
            end
            mdrun_command = [Settings.gmx_loc Settings.mdrun ' -s ' windows2unix(TPR_File) ...
                ' -o ' windows2unix(Minimization_TRR_File) ' -g ' windows2unix(Log_File) ...
                ' -e ' windows2unix(Energy_file) ' -c ' windows2unix(Minimized_Geom_File) ...
                ' -deffnm ' windows2unix(fullfile(Settings.WorkDir,'Prep_Liq')) ' -ntmpi 1'];
            
            if Table_Req
                mdrun_command = [mdrun_command ' -table ' windows2unix(Settings.TableFile_MX)];
            end
            [state,mdrun_output] = system(mdrun_command);
            
            if state ~= 0
                disp(mdrun_output);
                error(['Error running mdrun for liquid system minimization. Problem command: ' newline mdrun_command]);
            end
        end
    else
        if Settings.Verbose
            disp('Minimization step previously completed.')
        end
        Topology_Template_file = fullfile(Settings.home,'templates','Gromacs_Templates',...
        'Topology.template');
        Metal_Info = elements('Sym',Settings.Metal);
        Halide_Info = elements('Sym',Settings.Halide);
        Table_Req = IsGmxTableRequired(Settings);
        Settings.JobName = [Settings.Theory '_TestModel'];
        dat = load_gro_file(Minimized_Geom_File);
        if Settings.Polarization
            nmol_liquid = dat.N_atoms/4;
        else
            nmol_liquid = dat.N_atoms/2;
        end
        Settings.FileBase = 'Prep_Liq';
        ndx_add = add_polarization_shells(Settings,Minimized_Geom_File,'add_shells',false);
	end
    
%     system(['wsl source ~/.bashrc; echo "5 0" ^| gmx_d energy -f ' windows2unix(Energy_file) ' -o ' windows2unix(strrep(Energy_file,'.edr','.xvg'))])
%     En_xvg_file = fullfile(Settings.WorkDir,'Prep_Liq.xvg');
%     Data = import_xvg(En_xvg_file);
%     plot(Data(:,1),Data(:,2)./nmol_liquid) % Potential
%     ylim([-1000 1000])
    
    
    %% System is now minimized, run a fast equilibration to get equilibrium properties at requested T and P
    Equilibrate_TRR_File = fullfile(Settings.WorkDir,'Equil_Liq.trr'); % Relaxation started
    Equilibrated_Geom_File = fullfile(Settings.WorkDir,['MSD_Liq.' Settings.CoordType]); % Relaxation complete
    
    Run_Equilibration = true;
    if isfile(Equilibrated_Geom_File)
        try
            % Check integrity of equilibrated geom file
            Data = load_gro_file(Equilibrated_Geom_File);
            if Data.N_atoms >= Settings.N_atoms
                % Check to ensure minimization completed
                gmx_check = [Settings.gmx_loc Settings.g_check ' -f ' windows2unix(Equilibrate_TRR_File)];
                [state,outp] = system(gmx_check);
                lf = regexp(outp,'Step *([0-9]|\.)+ *([0-9]|\.)+\nTime','tokens','once');
                if state == 0 && ~isempty(lf)
                    traj_time = (str2double(lf{1})-1)*str2double(lf{2});
                    if traj_time >= Settings.Liquid_Equilibrate_Time
                        Run_Equilibration = false;
                    end
                end
            end
        catch
            Run_Equilibration = true;
        end
    end
    
    % Set the number of steps
    MD_nsteps = Settings.Liquid_Equilibrate_Time/Settings.MDP.dt;
    %Compressibility = Get_Alkali_Halide_Compressibility(Settings.Salt,'Isotropy','isotropic','Molten',true);
    Compressibility = Settings.QECompressibility; % bar^(-1)
    tau_p = Settings.MDP.dt; % ps
    tau_t = Settings.MDP.dt; % ps

    nstpcouple = max(round(tau_p/(20*Settings.MDP.dt)),1);
    nsttcouple = max(round(tau_t/(20*Settings.MDP.dt)),1);
    
    % Create new MDP and topology files
    % Load MDP template
    MDP_Template = fileread(fullfile(Settings.home,'templates','Gromacs_Templates',...
    'MDP_MD.template'));
    
    Settings.Topology_Text = fileread(Topology_Template_file);
    
    % Update topology text
    % Topology filename and directory for output
    Settings.Topology_File = fullfile(Settings.WorkDir,[Settings.JobName '.top']);

    % Load Topology template
    Settings.Topology_Text = fileread(fullfile(Settings.home,'templates','Gromacs_Templates',...
    'Topology.template'));

    % Add in global parameters to Topology template
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##GENPAIRS##',Settings.Top_gen_pairs);
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##FUDGELJ##',num2str(Settings.Top_fudgeLJ));
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##FUDGEQQ##',num2str(Settings.Top_fudgeQQ));
    
    % Insert element info into topology template
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##MET##',pad(Settings.Metal,2));
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##METZ##',pad(num2str(Metal_Info.atomic_number),3));
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMASS##',pad(num2str(Metal_Info.atomic_mass),7));
    if Settings.Polarization
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##MCHRG##',pad(num2str(Settings.S.QcoreM),2));
    else
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##MCHRG##',pad(num2str(Settings.S.Q),2));
    end
    
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##HAL##',pad(Settings.Halide,2));
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALZ##',pad(num2str(Halide_Info.atomic_number),3));
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALMASS##',pad(num2str(Halide_Info.atomic_mass),7));
    if Settings.Polarization
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##XCHRG##',pad(num2str(Settings.S.QcoreX),2));
    else
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##XCHRG##',pad(num2str(-Settings.S.Q),2));
    end
    
    if Table_Req
        % Define the function type as 1 (required for custom functions)
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##NBFUNC##','1');
        
        % Define the combination rules (Lorenz-berthelot)
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##COMBR##','1');
        
        % Define repulsive parameters as 1.0 (already included in potentials)
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETA##','1.0');
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALA##','1.0');
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALA##','1.0');
        
        % Generate tables of the potential
        [Settings.TableFile_MX,C6,Energygrptables] = MakeTables(Settings,'TableName',[Settings.JobName '_Table']);
        MDP_Template = strrep(MDP_Template,'##ENERGYGRPSTABLE##',strjoin(Energygrptables,' '));
                                
        % Dispersion coefficients
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETC##',num2str(C6.MM,'%.10e'));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALC##',num2str(C6.XX,'%.10e'));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALC##',num2str(C6.MX,'%.10e'));
        
        % Modify the MDP file
        MDP_Template = strrep(MDP_Template,'##VDWTYPE##',pad('user',18));
        MDP_Template = strrep(MDP_Template,'##CUTOFF##',pad('group',18));
        MDP_Template = regexprep(MDP_Template,'ewald-rtol-lj.+?\n','');
        MDP_Template = regexprep(MDP_Template,'lj-pme-comb-rule.+?\n','');
        MDP_Template = regexprep(MDP_Template,'verlet-buffer-tolerance.+?\n','');
        MDP_Template = strrep(MDP_Template,'##RLIST##',pad(num2str(Settings.MDP.RList_Cutoff),18));
        MDP_Template = strrep(MDP_Template,'##RCOULOMB##',pad(num2str(Settings.MDP.RCoulomb_Cutoff),18));
        MDP_Template = strrep(MDP_Template,'##RVDW##',pad(num2str(Settings.MDP.RVDW_Cutoff),18));
        MDP_Template = strrep(MDP_Template,'##VDWMOD##',pad('none',18));
        
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
        
        % Definte the function type as 1 (LJ)
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##NBFUNC##','1');
        
        % Define the combination rules (Lorenz-berthelot in sigma-epsilon form)
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##COMBR##','2');
        
        % Get JC parameters
        [MX_JC_Param,MM_JC_Param,XX_JC_Param] = JC_Potential_Parameters(Settings);
        
        % Add parameters to topology text
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETC##',pad(num2str(MM_JC_Param.sigma,'%10.8e'),10));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALC##',pad(num2str(XX_JC_Param.sigma,'%10.8e'),10));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALC##',pad(num2str(MX_JC_Param.sigma,'%10.8e'),10));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METMETA##',num2str(MM_JC_Param.epsilon,'%10.8e'));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##HALHALA##',num2str(XX_JC_Param.epsilon,'%10.8e'));
        Settings.Topology_Text = strrep(Settings.Topology_Text,'##METHALA##',num2str(MX_JC_Param.epsilon,'%10.8e'));
        
        % Modify the MDP file
        MDP_Template = strrep(MDP_Template,'##VDWTYPE##',pad(Settings.MDP.VDWType,18));
        MDP_Template = strrep(MDP_Template,'##CUTOFF##',pad(Settings.MDP.CutOffScheme,18));
        MDP_Template = regexprep(MDP_Template,'energygrp-table.+?\n','');
        MDP_Template = regexprep(MDP_Template,'ewald-rtol-lj.+?\n','');
        MDP_Template = regexprep(MDP_Template,'lj-pme-comb-rule.+?\n','');
        MDP_Template = strrep(MDP_Template,'##RLIST##',pad(num2str(Settings.MDP.RList_Cutoff),18));
        MDP_Template = strrep(MDP_Template,'##RCOULOMB##',pad(num2str(Settings.MDP.RCoulomb_Cutoff),18));
        MDP_Template = strrep(MDP_Template,'##RVDW##',pad(num2str(Settings.MDP.RVDW_Cutoff),18));
        MDP_Template = strrep(MDP_Template,'##VDWMOD##',pad(Settings.MDP.vdw_modifier,18));

        % Add in Verlet Settings
        if strcmp(Settings.MDP.CutOffScheme,'Verlet')
            MDP_Template = strrep(MDP_Template,'##VerletBT##',pad(num2str(Settings.MDP.VerletBT),18));
        else
            MDP_Template = regexprep(MDP_Template,'verlet-buffer-tolerance.+?\n','');
        end
    else
        error(['Warning: Unknown theory type: "' Settings.Theory '".'])
    end
    
    if Settings.MDP.Disp_Correction
        MDP_Template = [MDP_Template newline newline ...
            '; Long-range dispersion correction' newline ...
            'DispCorr                 = EnerPres          ; apply long range dispersion corrections for Energy and pressure'];
    end
    
    % Add in parameters to MDP template
    MDP_Template = strrep(MDP_Template,'##NSTEPS##',pad(num2str(MD_nsteps),18));
    MDP_Template = strrep(MDP_Template,'##INTEGR##',pad(Settings.MDP.integrator,18));
    MDP_Template = strrep(MDP_Template,'##TIMEST##',pad(num2str(Settings.MDP.dt),18));
    MDP_Template = strrep(MDP_Template,'##CONTINUE##',pad(Settings.MDP.continuation,18));
    MDP_Template = strrep(MDP_Template,'##REFTINIT##',pad(num2str(Settings.T0),18));
    MDP_Template = strrep(MDP_Template,'##COULOMB##',pad(Settings.MDP.CoulombType,18));
    MDP_Template = strrep(MDP_Template,'##FOURIER##',pad(num2str(Settings.MDP.Fourier_Spacing),18));
    MDP_Template = strrep(MDP_Template,'##PMEORDER##',pad(num2str(Settings.MDP.PME_Order),18));
    MDP_Template = strrep(MDP_Template,'##EWALDTOL##',pad(num2str(Settings.MDP.Ewald_rtol),18));
    MDP_Template = strrep(MDP_Template,'##LISTUPDATE##',pad(num2str(Settings.Update_NeighbourList),18));
    MDP_Template = strrep(MDP_Template,'##POSOUT##',pad(num2str(Settings.Output_Coords),18));
    MDP_Template = strrep(MDP_Template,'##VELOUT##',pad(num2str(Settings.Output_Velocity),18));
    MDP_Template = strrep(MDP_Template,'##FORCEOUT##',pad(num2str(Settings.Output_Forces),18));
    MDP_Template = strrep(MDP_Template,'##ENOUT##',pad(num2str(Settings.Output_Energies),18));
    MDP_Template = strrep(MDP_Template,'##CALCE##',pad(num2str(Settings.Calc_Energies),18));
    MDP_Template = strrep(MDP_Template,'##MET##',pad(Settings.Metal,3));
    MDP_Template = strrep(MDP_Template,'##HAL##',pad(Settings.Halide,3));
    
    % Remove annealing inputs from MDP
    MDP_Template = strrep(MDP_Template,'##ANNEALING##',pad('no',18));
    MDP_Template = regexprep(MDP_Template,'annealing-npoints +.+?\n','');
    MDP_Template = regexprep(MDP_Template,'annealing-time +.+?\n','');
    MDP_Template = regexprep(MDP_Template,'annealing-temp +.+?\n','');
    
    MDP_Template = strrep(MDP_Template,'##TITLE##',[Settings.Salt ' ' Settings.Theory ' TestModel']);
    
    if Settings.Polarization
        [Settings.Topology_Text,MDP_Template] = Polarize_Inputs(Settings,...
            Settings.Topology_Text,MDP_Template);
    else
        MDP_Template = strrep(MDP_Template,'##ENERGYGRPS##',[Settings.Metal ' ' Settings.Halide]);
    end
    
    % Save MDP Template
    MDP_Template_sv = MDP_Template;
    
    % Ensure fast equilibration with Berendsen barostat + small time constant
    MDP_Template = regexprep(MDP_Template,'(nstenergy += *)(.+?)( *);','$1100$3;');
    MDP_Template = strrep(MDP_Template,'##BAROSTAT##',pad('Berendsen',18));
    MDP_Template = strrep(MDP_Template,'##ISOTROPY##',pad('isotropic',18));
    MDP_Template = strrep(MDP_Template,'##PTIMECONST##',pad(num2str(tau_p),18));
    MDP_Template = strrep(MDP_Template,'##NSTPCOUPLE##',pad(num2str(nstpcouple),18));
    MDP_Template = strrep(MDP_Template,'##COMPRESS##',pad(num2str(Compressibility),18));
    MDP_Template = strrep(MDP_Template,'##REFP##',pad(num2str(Settings.Target_P(1)),18));

    % Pair it with velocity rescale thermostat + small time constant
    MDP_Template = strrep(MDP_Template,'##THERMOSTAT##',pad('v-rescale',18));
    MDP_Template = strrep(MDP_Template,'##TTIMECONST##',pad(num2str(tau_t),18));
    MDP_Template = strrep(MDP_Template,'##NSTTCOUPLE##',pad(num2str(nsttcouple),18));
    MDP_Template = strrep(MDP_Template,'##REFT##',pad(num2str(Settings.T0),18));

    % Save MDP file
    MDP_Filename = fullfile(Settings.WorkDir,'Equil_Liq.mdp');
    fidMDP = fopen(MDP_Filename,'wt');
    fwrite(fidMDP,regexprep(MDP_Template,'\r',''));
    fclose(fidMDP);

    % Finish the topology file: add in title and the atom list
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##N##x##N##x##N##',num2str(nmol_liquid));
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##GEOM##','molecule liquid');
    Atomlist = copy_atom_order(Minimized_Geom_File);
    Settings.Topology_Text = strrep(Settings.Topology_Text,'##LATOMS##',Atomlist);
    Top_Filename = fullfile(Settings.WorkDir,'Equil_Liq.top');

    % Save topology file
    fidTOP = fopen(Top_Filename,'wt');
    fwrite(fidTOP,regexprep(Settings.Topology_Text,'\r',''));
    fclose(fidTOP);
    
    if Run_Equilibration
        
        % Check for a checkpoint file
        cpt_file = fullfile(Settings.WorkDir,'Equil_Liq.cpt');
        prev_cpt_file = fullfile(Settings.WorkDir,'Equil_Liq_prev.cpt');
        
        add_cpt = '';
        if isfile(cpt_file) || isfile(prev_cpt_file)
            gmx_check = [Settings.gmx_loc Settings.g_check ' -f ' windows2unix(cpt_file)];
            [state,~] = system(gmx_check);
            if state == 0
                add_cpt = [' -cpi ' windows2unix(cpt_file)];
            elseif isfile(prev_cpt_file)
                gmx_check = [Settings.gmx_loc Settings.g_check ' -f ' windows2unix(prev_cpt_file)];
                [state,~] = system(gmx_check);
                if state == 0
                    add_cpt = [' -cpi ' windows2unix(prev_cpt_file)];
                end
            end
        end

        TPR_File = fullfile(Settings.WorkDir,'Equil_Liq.tpr');
        MDPout_File = fullfile(Settings.WorkDir,'Equil_Liq_out.mdp');
        GrompLog_File = fullfile(Settings.WorkDir,'Equil_Liq_Grompplog.log');
        
        if ~isfile(TPR_File) || isempty(add_cpt)
            FEquil_Grompp = [Settings.gmx_loc Settings.grompp ' -c ' windows2unix(Minimized_Geom_File) ...
                ' -f ' windows2unix(MDP_Filename) ' -p ' windows2unix(Top_Filename) ...
                ' -o ' windows2unix(TPR_File) ' -po ' windows2unix(MDPout_File) ...
                ndx_add ' -maxwarn ' num2str(Settings.MaxWarn) Settings.passlog windows2unix(GrompLog_File)];
            [state,~] = system(FEquil_Grompp);

            % Catch errors in grompp
            if state ~= 0
                error(['Error running GROMPP. Problem command: ' newline FEquil_Grompp]);
            else
                delete(GrompLog_File)
            end
        end

        % Prepare Equilibration mdrun command
        Log_File = fullfile(Settings.WorkDir,'Equil_Liq.log');
        Energy_file = fullfile(Settings.WorkDir,'Equil_Liq.edr');
        
        mdrun_command = [Settings.gmx Settings.mdrun ' -s ' windows2unix(TPR_File) ...
            ' -o ' windows2unix(Equilibrate_TRR_File) ' -g ' windows2unix(Log_File) ...
            ' -e ' windows2unix(Energy_file) ' -c ' windows2unix(Equilibrated_Geom_File) add_cpt ...
            ' -deffnm ' windows2unix(fullfile(Settings.WorkDir,'Equil_Liq')) ...
            Settings.mdrun_opts];
        
        if Table_Req
            mdrun_command = [mdrun_command ' -table ' windows2unix(Settings.TableFile_MX)];
        end

        % Run Liquid Equilibration
        if Settings.Verbose
            disp(['(1/2) Begining Liquid Equilibration for ' num2str(Settings.Liquid_Equilibrate_Time) ' ps...'] )
        end
        mintimer = tic;
        [state,mdrun_output] = system(mdrun_command);
        if state == 0
            if Settings.Verbose
                disp(['(1/2) Liquid Successfully Equilibrated! Epalsed Time: ' datestr(seconds(toc(mintimer)),'HH:MM:SS')]);
            end
        else
            try % Clean up
                [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.WorkDir) ' -iname "#*#" ' Settings.pipe ' xargs rm']);
                [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.OuterDir) ' -iname "*core*" ' Settings.pipe ' xargs rm']);
            catch me
                disp(me.message)
            end
            WorkDir = Settings.WorkDir;
            Settings = Inp_Settings;
            Settings.WorkDir = WorkDir;
            
            if ~isempty(regexp(mdrun_output,'[box|cell] size','match','once'))
                if Settings.Verbose
                    disp('Equilibration failed due to shrinking box. Increasing box size.')
                end
                if isfile(cpt_file)
                    delete(cpt_file)
                end
                if isfile(prev_cpt_file)
                    delete(prev_cpt_file)
                end
                if isfile(Equilibrated_Geom_File)
                    delete(Equilibrated_Geom_File)
                end
                if isfile(Minimized_Geom_File)
                    delete(Minimized_Geom_File)
                end
                % System shrunk too far, increase buffer size
                Settings.Cutoff_Buffer = Settings.Cutoff_Buffer*1.25;
                Settings.ScaleInitialLiqDensity = Settings.ScaleInitialLiqDensity*0.95;
                Output = Calc_Liquid_Properties_at_MP(Settings);
                return
            elseif Settings.MDP.dt/2 >= Settings.MinTimeStep
                if Settings.Verbose
                    disp('Liquid Equilibration failed. Reducing time step.')
                end
                Settings.MDP.dt = Settings.MDP.dt/2;
                Settings.Output_Coords = Settings.Output_Coords*2;
                if isfile(cpt_file)
                    delete(cpt_file);
                end
                if isfile(prev_cpt_file)
                    delete(prev_cpt_file);
                end
                Output = Calc_Liquid_Properties_at_MP(Settings);
                return
            else
                if Settings.Verbose
                    disp('Liquid equilibration failed.')
                    disp('Model may be completely unstable!')
                    disp(['WorkDir: ' WorkDir])
                end
                Output.Liquid_V_MP = nan;
                Output.Liquid_H_MP = nan;
                Output.Liquid_DM_MP = nan;
                Output.Liquid_DX_MP = nan;
                cleanup_folder(Settings,Output_File,Output)
                return
            end
        end
    else
        if Settings.Verbose
            disp('Equilibration step previously completed.')
        end
    end
    
%     system(['wsl source ~/.bashrc; echo "5 15 0" ^| gmx_d energy -f ' windows2unix(Energy_file) ' -o ' windows2unix(strrep(Energy_file,'.edr','.xvg'))])
%     En_xvg_file = fullfile(Settings.WorkDir,'Equil_Liq.xvg');
%     Data = import_xvg(En_xvg_file);
%     plot(Data(:,1),Data(:,2)./nmol_liquid) % Potential
%     plot(Data(:,1),(10^3).*Data(:,3)./nmol_liquid) % Volume
    
    % Check to ensure system remained liquid
    PyOut = py.LiXStructureDetector.Calculate_Liquid_Fraction(Settings.WorkDir, Settings.Salt, ...
        pyargs('SystemName','Equil_Liq',...
        'RefStructure','Liquid',...
        'CheckFullTrajectory',true,...
        'FileType',Settings.CoordType,...
        'ML_TimeLength',0,...
        'ML_TimeStep',0,...
        'TimePerFrame',Settings.Output_Coords*Settings.MDP.dt,...
        'SaveTrajectory',true,...
        'SavePredictionsImage',true));
    Liq_Fraction = PyOut{4};
    
    if Liq_Fraction < 0.85
        if Settings.Verbose
            disp('Detected Liquid Freezing at Experimental MP')
        end
        Output.Liquid_V_MP = nan;
        Output.Liquid_H_MP = nan;
        Output.Liquid_DM_MP = nan;
        Output.Liquid_DX_MP = nan;
        cleanup_folder(Settings,Output_File,Output)
        return
    end
    
    %% Calculate metal ion diffusion coefficient - Start with a simulation using normal barostat/thermostat settings
    Dynamics_TRR_File = fullfile(Settings.WorkDir,'MSD_Liq.trr'); % Production started
    Final_Geom_File = fullfile(Settings.WorkDir,['MSD_Liq_out.' Settings.CoordType]); % Production complete
    Final_Energy_File = fullfile(Settings.WorkDir,'MSD_Liq.edr');
    
    Run_Dynamics = true;
    if isfile(Final_Geom_File) && isfile(Final_Energy_File)
        try
            % Check integrity of equilibrated geom file
            Data = load_gro_file(Final_Geom_File);
            if Data.N_atoms >= Settings.N_atoms
                % Check to ensure minimization completed
                gmx_check = [Settings.gmx_loc Settings.g_check ' -f ' windows2unix(Dynamics_TRR_File)];
                [state,outp] = system(gmx_check);
                lf = regexp(outp,'Step *([0-9]|\.)+ *([0-9]|\.)+\nTime','tokens','once');
                if state == 0 && ~isempty(lf)
                    traj_time = (str2double(lf{1})-1)*str2double(lf{2});
                    if traj_time >= Settings.Liquid_Test_Time
                        Run_Dynamics = false;
                    end
                end
            end
        catch
            Run_Dynamics = true;
        end
    end
    
    if Run_Dynamics
        % Check for a checkpoint file
        cpt_file = fullfile(Settings.WorkDir,'MSD_Liq.cpt');
        prev_cpt_file = fullfile(Settings.WorkDir,'MSD_Liq_prev.cpt');
        
        add_cpt = '';
        if isfile(cpt_file) || isfile(prev_cpt_file)
            gmx_check = [Settings.gmx_loc Settings.g_check ' -f ' windows2unix(cpt_file)];
            [state,~] = system(gmx_check);
            if state == 0
                add_cpt = [' -cpi ' windows2unix(cpt_file)];
            elseif isfile(prev_cpt_file)
                gmx_check = [Settings.gmx_loc Settings.g_check ' -f ' windows2unix(prev_cpt_file)];
                [state,~] = system(gmx_check);
                if state == 0
                    add_cpt = [' -cpi ' windows2unix(prev_cpt_file)];
                end
            end
        end
        
        MD_nsteps = Settings.Liquid_Test_Time/Settings.MDP.dt;
        MDP_Template = regexprep(MDP_Template_sv,'(nstenergy += *)(.+?)( *);','$1100$3;');
        MDP_Template = regexprep(MDP_Template,'(nsteps += *)(.+?)( *);',['$1' num2str(MD_nsteps) '$3;']);
        xyz_out = num2str(0.1 / Settings.MDP.dt); % Output coords every 0.1 ps
        MDP_Template = regexprep(MDP_Template,'(nstxout += *)(.+?)( *);',['$1' xyz_out '$3;']);

        % Thermostat settings
        MDP_Template = strrep(MDP_Template,'##THERMOSTAT##',pad(Settings.Thermostat,18));
        MDP_Template = strrep(MDP_Template,'##TTIMECONST##',pad(num2str(Settings.Time_Constant_T),18));
        MDP_Template = strrep(MDP_Template,'##NSTTCOUPLE##',pad(num2str(Settings.Nsttcouple),18));
        MDP_Template = strrep(MDP_Template,'##REFT##',pad(num2str(Settings.T0),18));
        MDP_Template = regexprep(MDP_Template,'(gen-vel += *)(.+?)( *);','$1no$3;');
        MDP_Template = regexprep(MDP_Template,'gen-temp.+?\n','');

        % Barostat settings
        % Get box compressibility based on the salt
        Settings.Isotropy = 'isotropic';
        Compressibility = Get_Alkali_Halide_Compressibility(Settings.Salt,...
            'Isotropy',Settings.Isotropy,'Molten',Settings.UseMoltenCompressibility,...
            'ScaleFactor',Settings.ScaleCompressibility);

        MDP_Template = strrep(MDP_Template,'##BAROSTAT##',pad(Settings.Barostat,18));
        MDP_Template = strrep(MDP_Template,'##ISOTROPY##',pad(num2str(Settings.Isotropy),18));
        MDP_Template = strrep(MDP_Template,'##COMPRESS##',pad(num2str(Compressibility),18));
        MDP_Template = strrep(MDP_Template,'##REFP##',pad(num2str(Settings.Target_P(1)),18));
        MDP_Template = strrep(MDP_Template,'##PTIMECONST##',pad(num2str(Settings.Time_Constant_P),18));
        MDP_Template = strrep(MDP_Template,'##NSTPCOUPLE##',pad(num2str(Settings.Nstpcouple),18));

        % Save MDP file
        MDP_Filename = fullfile(Settings.WorkDir,'MSD_Liq.mdp');
        fidMDP = fopen(MDP_Filename,'wt');
        fwrite(fidMDP,regexprep(MDP_Template,'\r',''));
        fclose(fidMDP);

        TPR_File = fullfile(Settings.WorkDir,'MSD_Liq.tpr');
        MDPout_File = fullfile(Settings.WorkDir,'MSD_Liq_out.mdp');
        GrompLog_File = fullfile(Settings.WorkDir,'MSD_Liq_Grompplog.log');
        
        if ~isfile(TPR_File) || isempty(add_cpt)
            FEquil_Grompp = [Settings.gmx_loc Settings.grompp  ' -c ' windows2unix(Equilibrated_Geom_File) ...
                ' -f ' windows2unix(MDP_Filename) ' -p ' windows2unix(Top_Filename) ...
                ' -o ' windows2unix(TPR_File) ' -po ' windows2unix(MDPout_File) ...
                ndx_add ' -maxwarn ' num2str(Settings.MaxWarn) Settings.passlog windows2unix(GrompLog_File)];
            [state,~] = system(FEquil_Grompp);
            
            % Catch errors in grompp
            if state ~= 0
                grompp_output = fileread(GrompLog_File);
                
                if ~isempty(regexp(grompp_output,'[box|cell] size','match','once'))
                    if Settings.Verbose
                        disp('Box has shrunk too far, retrying with larger box size.');
                    end
                    if isfile(cpt_file)
                        delete(cpt_file)
                    end
                    if isfile(prev_cpt_file)
                        delete(prev_cpt_file)
                    end
                    if isfile(fullfile(Settings.WorkDir,'Equil_Liq.cpt'))
                        delete(fullfile(Settings.WorkDir,'Equil_Liq.cpt'));
                    end
                    if isfile(fullfile(Settings.WorkDir,'Equil_Liq_prev.cpt'))
                        delete(fullfile(Settings.WorkDir,'Equil_Liq_prev.cpt'))
                    end
                    if isfile(Equilibrated_Geom_File)
                        delete(Equilibrated_Geom_File)
                    end
                    if isfile(Minimized_Geom_File)
                        delete(Minimized_Geom_File)
                    end
                    
                    WorkDir = Settings.WorkDir;
                    Settings = Inp_Settings;
                    Settings.WorkDir = WorkDir;
                    Settings.Cutoff_Buffer = Settings.Cutoff_Buffer.*1.25;
                    Settings.ScaleInitialLiqDensity = Settings.ScaleInitialLiqDensity*0.95;
                    Output = Calc_Liquid_Properties_at_MP(Settings);
                    return
                    
                else
                    error(['Error running GROMPP. Problem command: ' newline FEquil_Grompp]);
                end
            else
                delete(GrompLog_File)
            end
        end

        % Prepare Equilibration mdrun command
        Log_File = fullfile(Settings.WorkDir,'MSD_Liq.log');

        mdrun_command = [Settings.gmx Settings.mdrun ' -s ' windows2unix(TPR_File) ...
            ' -o ' windows2unix(Dynamics_TRR_File) ' -g ' windows2unix(Log_File) ...
            ' -e ' windows2unix(Final_Energy_File) ' -c ' windows2unix(Final_Geom_File) add_cpt ...
            ' -deffnm ' windows2unix(fullfile(Settings.WorkDir,'MSD_Liq')) ...
            Settings.mdrun_opts];
        
        if Table_Req
            mdrun_command = [mdrun_command ' -table ' windows2unix(Settings.TableFile_MX)];
        end
        
        % Run Liquid Equilibration
        if Settings.Verbose
            disp(['(2/2) Running liquid with realistic dynamics for ' num2str(Settings.Liquid_Test_Time) ' ps...'] )
        end
        mintimer = tic;
        [state,mdrun_output] = system(mdrun_command);
        if state == 0
            if Settings.Verbose
                disp(['(2/2) Liquid dynamics simulation complete. Epalsed Time: ' datestr(seconds(toc(mintimer)),'HH:MM:SS')]);
            end
        else
            try % Clean up
                [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.WorkDir) ' -iname "#*#" ' Settings.pipe ' xargs rm']);
                [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.OuterDir) ' -iname "*core*" ' Settings.pipe ' xargs rm']);
            catch me
                disp(me.message)
            end
            
            WorkDir = Settings.WorkDir;
            Settings = Inp_Settings;
            Settings.WorkDir = WorkDir;
            if ~isempty(regexp(mdrun_output,'[box|cell] size','match','once'))
                if Settings.Verbose
                    disp('Equilibration failed due to shrinking box. Increasing box size.')
                end
                if isfile(cpt_file)
                    delete(cpt_file)
                end
                if isfile(prev_cpt_file)
                    delete(prev_cpt_file)
                end
                if isfile(fullfile(Settings.WorkDir,'Equil_Liq.cpt'))
                    delete(fullfile(Settings.WorkDir,'Equil_Liq.cpt'));
                end
                if isfile(fullfile(Settings.WorkDir,'Equil_Liq_prev.cpt'))
                    delete(fullfile(Settings.WorkDir,'Equil_Liq_prev.cpt'))
                end
                if isfile(Equilibrated_Geom_File)
                    delete(Equilibrated_Geom_File)
                end
                if isfile(Minimized_Geom_File)
                    delete(Minimized_Geom_File)
                end
                if isfile(Final_Geom_File)
                    delete(Final_Geom_File)
                end
                
                % System shrunk too far, increase buffer size
                Settings.Cutoff_Buffer = Settings.Cutoff_Buffer*1.25;
                Settings.ScaleInitialLiqDensity = Settings.ScaleInitialLiqDensity*0.95;
                Output = Calc_Liquid_Properties_at_MP(Settings);
                return
            elseif Settings.MDP.dt/2 >= Settings.MinTimeStep
                if Settings.Verbose
                    disp(['Liquid dynamics failed. Restarting with reduced time step. Epalsed Time: ' datestr(seconds(toc(mintimer)),'HH:MM:SS')])
                end
                Settings.MDP.dt = Settings.MDP.dt/2;
                Settings.Output_Coords = Settings.Output_Coords*2;
                
                if isfile(cpt_file) 
                    delete(cpt_file)
                end
                if isfile(prev_cpt_file)
                    delete(prev_cpt_file)
                end
                Output = Calc_Liquid_Properties_at_MP(Settings);
                return
            else
                if Settings.Verbose
                    disp(['Liquid dynamics failed. Epalsed Time: ' datestr(seconds(toc(mintimer)),'HH:MM:SS')])
                    disp('Model may be completely unstable!')
                    disp(['WorkDir: ' WorkDir])
                    disp(mdrun_output)
                end
                Output.Liquid_V_MP = nan;
                Output.Liquid_H_MP = nan;
                Output.Liquid_DM_MP = nan;
                Output.Liquid_DX_MP = nan;
                cleanup_folder(Settings,Output_File,Output)
                return
            end
        end
    else
        if Settings.Verbose
            disp('System dynamics step previously completed.')
        end
        TPR_File = fullfile(Settings.WorkDir,'MSD_Liq.tpr');
    end
    
    % Check to ensure system remained liquid
    PyOut = py.LiXStructureDetector.Calculate_Liquid_Fraction(Settings.WorkDir, Settings.Salt, ...
        pyargs('SystemName','MSD_Liq',...
        'RefStructure','Liquid',...
        'CheckFullTrajectory',true,...
        'FileType',Settings.CoordType,...
        'ML_TimeLength',0,...
        'ML_TimeStep',0,...
        'TimePerFrame',Settings.Output_Coords*Settings.MDP.dt,...
        'SaveTrajectory',true,...
        'SavePredictionsImage',true));
    Liq_Fraction = PyOut{4};
    
    if Liq_Fraction < 0.85
        if Settings.Verbose
            disp('Detected Liquid Freezing at Experimental MP')
        end
        Output.Liquid_V_MP = nan;
        Output.Liquid_H_MP = nan;
        Output.Liquid_DM_MP = nan;
        Output.Liquid_DX_MP = nan;
        cleanup_folder(Settings,Output_File,Output)
        return
    end
    
    %% Calculate volume and enthalpy of liquid
    En_xvg_file = fullfile(Settings.WorkDir,'MSD_Liq_Energy.xvg');
    
    % Check energy options
    gmx_command = [Settings.wsl 'echo "0" ' Settings.pipe ...
        ' ' strrep(Settings.gmx_loc,Settings.wsl,'') Settings.g_energy ...
        ' -f ' windows2unix(Final_Energy_File) ' -s ' windows2unix(TPR_File)];
    [~,outpt] = system(gmx_command);
    
    en_opts = regexp(outpt,'End your selection with an empty line or a zero.\n-+(.+?)\n\n','tokens','once');
    en_opts = en_opts{1};
    En_set = '';
    En_set = [En_set ' ' char(regexp(en_opts,'([0-9]{1,2})  Volume','tokens','once'))];
    En_set = [En_set ' ' char(regexp(en_opts,'([0-9]{1,2})  Enthalpy','tokens','once'))];
    En_set = [En_set ' 0'];
    En_set = regexprep(En_set,' +',' ');
    
    % Grab data from results
    startpoint = 0; % ps
    gmx_command = [Settings.wsl 'echo ' En_set ' ' Settings.pipe ...
        ' ' strrep(Settings.gmx_loc,Settings.wsl,'') Settings.g_energy ...
        ' -f ' windows2unix(Final_Energy_File) ' -o ' windows2unix(En_xvg_file) ...
        ' -s ' windows2unix(TPR_File) ' -b ' num2str(startpoint) ...
        ' -e ' num2str(Settings.Liquid_Test_Time)];
    [err,~] = system(gmx_command);
    if err ~= 0
        error('Failed to collect energy data.')
    end
    
    Data = import_xvg(En_xvg_file); % Gather X,Y,Z lengths
    
    Output.Liquid_V_MP = mean(Data(:,2))*(10^3)/nmol_liquid; % A^3 / ion pair
    Output.Liquid_H_MP = mean(Data(:,3))/nmol_liquid; % kJ/mol
    
    %% MSD Calculation to check
    MSD_File = fullfile(Settings.WorkDir,'MSD_Liq_msd.xvg');
    MSD_Log_File = fullfile(Settings.WorkDir,'MSD_Liq_msd.log');
    msd_command = [Settings.wsl 'echo ' Settings.Metal ' ' Settings.pipe ' '  strrep(Settings.gmx_loc,Settings.wsl,'') ...
        Settings.g_msd ' -f ' windows2unix(Dynamics_TRR_File) ' -s ' windows2unix(TPR_File) ...
        ' -o ' windows2unix(MSD_File) ' -b 0 -e ' num2str(Settings.Liquid_Test_Time) ...
        ' -trestart 0.1 -beginfit ' num2str(0.125*Settings.Liquid_Test_Time) ...
        ' -endfit ' num2str(0.75*Settings.Liquid_Test_Time) Settings.passlog windows2unix(MSD_Log_File)];
    
    [~,~] = system(msd_command);
    outp = fileread(MSD_Log_File);
    try
        Diff_txt = regexp(outp,['D\[ *' Settings.Metal '\] *([0-9]|\.|e|-|\+)+ *(\(.+?\)) *([0-9]|\.|e|-|\+)+'],'tokens','once');
        Output.Liquid_DM_MP = str2double(Diff_txt{1})*str2double(Diff_txt{3}); % cm^2 / s
    catch
        if isfield(Settings,'Retry') && Settings.Retry
            if Settings.Verbose
                error('Failed to gather metal diffusion constant on retry attempt!')
            end
        else
            if Settings.Verbose
                disp('Failed to gather metal diffusion constant, retrying...')
            end
            try % Clean up
                [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.WorkDir) ' -iname "#*#" ' Settings.pipe ' xargs rm']);
                [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.OuterDir) ' -iname "*core*" ' Settings.pipe ' xargs rm']);
            catch me
                disp(me.message)
            end
            WorkDir = Settings.WorkDir;
            Settings = Inp_Settings;
            Settings.WorkDir = WorkDir;
            Settings.Retry = true;
            Output = Calc_Liquid_Properties_at_MP(Settings);
            return
        end
    end

    if Settings.CheckAmorphousLiquid && Output.Liquid_DM_MP <= Settings.Finite_T_Data.Exp_DM_MP/100
        if Settings.Verbose
            disp('Detected liquid has hardened to amorphous solid.')
        end
        Output.Liquid_V_MP = nan;
        Output.Liquid_H_MP = nan;
        Output.Liquid_DX_MP = nan;
        save(Output_File,'Output');
        diary off
        if isfield(Settings,'Diary_Loc') && ~isempty(Settings.Diary_Loc)
            diary(Settings.Diary_Loc)
        end
        return
    end
    
    if Settings.CheckAmorphousHalide
        MSD_File = fullfile(Settings.WorkDir,'MSD_Liq_msd_halide.xvg');
        MSD_Log_File = fullfile(Settings.WorkDir,'MSD_Liq_msd_halide.log');
        msd_command = [Settings.wsl 'echo ' Settings.Halide ' ' Settings.pipe ' '  strrep(Settings.gmx_loc,Settings.wsl,'') ...
            Settings.g_msd ' -f ' windows2unix(Dynamics_TRR_File) ' -s ' windows2unix(TPR_File) ...
            ' -o ' windows2unix(MSD_File) ' -b 0 -e ' num2str(Settings.Liquid_Test_Time) ...
            ' -trestart 0.1 -beginfit ' num2str(0.125*Settings.Liquid_Test_Time) ...
            ' -endfit ' num2str(0.75*Settings.Liquid_Test_Time) Settings.passlog windows2unix(MSD_Log_File)];
        [~,~] = system(msd_command);
        outp = fileread(MSD_Log_File);
        try
            Diff_txt = regexp(outp,['D\[ *' Settings.Halide '\] *([0-9]|\.|e|-|\+)+ *(\(.+?\)) *([0-9]|\.|e|-|\+)+'],'tokens','once');
            Output.Liquid_DX_MP = str2double(Diff_txt{1})*str2double(Diff_txt{3}); % cm^2 / s
        catch
            if isfield(Settings,'Retry') && Settings.Retry
                if Settings.Verbose
                    error('Failed to gather halide diffusion constant on retry attempt!')
                end
            else
                if Settings.Verbose
                    disp('Failed to gather halide diffusion constant, retrying...')
                end
                try % Clean up
                    [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.WorkDir) ' -iname "#*#" ' Settings.pipe ' xargs rm']);
                    [~,~] = system([Settings.wsl 'find ' windows2unix(Settings.OuterDir) ' -iname "*core*" ' Settings.pipe ' xargs rm']);
                catch me
                    disp(me.message)
                end
                WorkDir = Settings.WorkDir;
                Settings = Inp_Settings;
                Settings.WorkDir = WorkDir;
                Settings.Retry = true;
                Output = Calc_Liquid_Properties_at_MP(Settings);
                return
            end
        end
    else
        Output.Liquid_DX_MP = nan;
    end
    
    % plot(Data(:,1),(10^3).*Data(:,2)./nmol_liquid)
    % V = mean((10^3).*Data(timesteps/2:end,2)./nmol_liquid) % A^3/molecule
    % stdevV = std((10^3).*Data(timesteps/2:end,2)./nmol_liquid) % A^3/molecule
    if Settings.Verbose
        disp('*** Separate Equilibration of Liquid Complete ***')
    end
    cleanup_folder(Settings,Output_File,Output)
    
    % Clean up the calculation directory
    % Get a list of all files in this folder.
    function cleanup_folder(Settings,Output_File,Output)
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
                case {'Calc_Settings.mat' 'Calculation_diary.log' 'Calc_Output.mat'}
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
end