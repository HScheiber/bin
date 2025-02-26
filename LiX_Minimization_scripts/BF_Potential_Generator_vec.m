function U = BF_Potential_Generator_vec(Settings)

%% Load BH Parameters
dat = load(fullfile(Settings.home,'data','BH_Default_Param.mat'));
QQ_prefactor = dat.QQ_prefactor;

%% Parameter: q (charge)
q.M =  Settings.S.Q; % atomic
q.X = -Settings.S.Q; % atomic

%% Parameters of interest for vdW potential
sigma.MX = Settings.S.S.MX; % nm
sigma.MM = Settings.S.S.MM;
sigma.XX = Settings.S.S.XX;

epsilon.MX = Settings.S.E.MX; % kJ/mol
epsilon.MM = Settings.S.E.MM;
epsilon.XX = Settings.S.E.XX;

gamma.MX = Settings.S.G.MX; % unitless
gamma.MM = Settings.S.G.MM;
gamma.XX = Settings.S.G.XX;

%% Generate range (r) in nm
U.r = Settings.Table_StepSize:Settings.Table_StepSize:Settings.Table_Length;

%% Build the PES
for interaction = {'MX' 'XX' 'MM'}
    int = interaction{1};
    
    Kappa = 2.*epsilon.(int)./(1 - (3./(gamma.(int) + 3)));
    Beta = Kappa.*(3./(gamma.(int) + 3));
    D = (sigma.(int).^6)./((sigma.(int).^6) + (U.r.^6));
    C6 = Kappa.*(sigma.(int).^6);
    
    %% Build PES
    [f,~]= Coulomb_Potential(Settings,U.r,int);
    U.(int) = QQ_prefactor.*q.(int(1)).*q.(int(2)).*f + Beta.*D.*exp(gamma.(int).*(1 - (U.r./sigma.(int)))) - C6./(sigma.(int).^6 + U.r.^6);
    
    % Shift the potential to zero at the cutoff
    if contains(Settings.MDP.vdw_modifier,'potential-shift','IgnoreCase',true)
        D_VDW = (sigma.(int).^6)./((sigma.(int).^6) + (Settings.MDP.RVDW_Cutoff.^6));
        EVDW_Cutoff = Beta.*D_VDW.*exp(gamma.(int).*(1 - (Settings.MDP.RVDW_Cutoff./sigma.(int)))) ...
                    - C6./(sigma.(int).^6 + Settings.MDP.RVDW_Cutoff.^6);
        
        U.(int) = U.(int) - EVDW_Cutoff;
    end
    
end

end