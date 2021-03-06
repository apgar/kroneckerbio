function SymModel = simbio2Symbolic(SimbioModel, opts)
%simbio2Symbolic converts a Simbiology model into a structure of symbolic
%   variables so that differentiation and other mathematical manipulation
%   can be done on the system.
% 
%   SymModel = simbio2Symbolic(SimbioModel, opts)
%
%   Inputs
%   SimbioModel: [ Simbiology model scalar ]
%       A Simbiology model object
%   opts: [ options struct scalar {} ]
%       .Verbose [ logical scalar {false} ]
%       	Print progress to command window
%       .Order [ 0 | 1 | {2} | 3 ]
%       	Determines how deep the derivatives should be taken. Each level
%       	increases the cost exponentially, but increases the number of
%       	Kronecker functions that can be run on the model.
%
%   Outputs
%   SymModel
%       .Type: [ 'Model.SymbolicReactions' ]
%       .Name: [ string ]
%           Copied from SimbioModel.Name
%       .nv: [ nonegative integer scalar ]
%           Number of compartments
%       .nk: [ nonegative integer scalar ]
%           Number of kinetic parameters
%       .ns: [ nonegative integer scalar ]
%           Number of seed parameters
%       .nq: [ nonegative integer scalar ]
%           Number of input control parameters
%       .nu: [ nonegative integer scalar ]
%           Number of inputs
%       .nx: [ nonegative integer scalar ]
%           Number of states
%       .nr: [ nonegative integer scalar ]
%           Number of reactions
%       .vSyms: [ symbolic vector nv ]
%           Symbolic name of each compartment
%       .vNames: [ cell vector of strings nv ]
%           Natural names of the compartments
%       .v: [ positive vector nv ]
%           Sizes of the compartments
%       .kSyms: [ symbolic vector nk ]
%           Symbolic name of each kinetic parameter
%       .kNames: [ cell vector nk of strings ]
%           Natural names of the kinetic parameters
%       .k: [ nonegative vector nk ]
%           Kinetic parameter values
%       .sNames: [ cell vector of strings ns ]
%           Natural names of the seed parameters
%       .s: [ nonegative vector ns ]
%           Seed parameter values
%       .q: [ nonegative vector nq ]
%           Input control parameter values
%       .uSyms: [ symbolic vector nu ]
%           Symbolic name of each input species
%       .uNames: [ cell vector of strings nu ]
%           Natural names of the input species
%       .uInd [ positive integer vector nu ]
%           Index of the compartment to which the inputs belong
%       .u: [ symbolic vector nu ]
%           Symbolic representation of each input species
%       .xSyms: [ symbolic vector nx ]
%           Symbolic name of each state species
%       .xInd [ positive integer vector nx ]
%           Index of the compartment to which the states belong
%       .xNames: [ cell vector of strings nx ]
%           Natural names of the state species
%       .dx0ds: [ nonegative matrix nx by ns ]
%           The influence of each seed parameter on each state species's
%           initial amount
%       .x0 [ symbolic vector nx ]
%           Initial conditions of the state species
%       .r [ symbolic vector nr ]
%           Symbolic representation of each reaction rate using the
%           symbolic species and parameters
%       .S [ matrix nx by nr ]
%           The stoichiometry matrix of the reactions
%       .Su [ matrix nx by nr ]
%           A stoichiometry matrix of how the reactions are trying to alter
%           the inputs

% (c) 2013 David R Hagen & Bruce Tidor
% This work is released under the MIT license.

%% Options
% Resolve missing inputs
if nargin < 2
    opts = [];
end

% Options for displaying progress
defaultOpts.Verbose = 0;

opts = mergestruct(defaultOpts, opts);

verbose = logical(opts.Verbose);
opts.Verbose = max(opts.Verbose-1,0);

% Copy model object
SimbioModel = copyobj(SimbioModel);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 1: Extracting the Model Variables %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if verbose; fprintf('Extracting model components...'); end
%% Model name
name = SimbioModel.Name;

%% Build up the table of compartments
compartments = SimbioModel.Compartments;

nv = numel(compartments);
vNames  = cell(nv,1);
v = zeros(nv,1);

for iv = 1:nv
    vNames{iv}  = compartments(iv).Name;
    v(iv)       = compartments(iv).Capacity;
end

%% Build up the table of species
species = SimbioModel.Species;

nxu = numel(species);
xuNames  = cell(nxu,1);
xu0      = zeros(nxu,1);
vxuInd   = zeros(nxu,1);
isu      = false(nxu,1);

for ixu = 1:nxu
    xuNames{ixu}  = species(ixu).Name;
    xu0(ixu)      = species(ixu).InitialAmount;
    vxuInd(ixu)   = find(strcmp(species(ixu).Parent.Name, vNames));
    isu(ixu)      = species(ixu).BoundaryCondition || species(ixu).ConstantAmount;
end

%% Build up the table of constants
constants = SimbioModel.Parameters;

nk = numel(constants); % Total number of parameters (may change)
nkm = nk; % Number of model parameters
kNames = cell(nk,1);
k      = zeros(nk,1);

% Get model parameters
for ik = 1:nk
    kNames{ik} = constants(ik).Name;
    k(ik)      = constants(ik).Value;
end

% Get kinetic law parameters
reactions = SimbioModel.Reactions;

nr = numel(reactions);

for ir = 1:nr
    kineticlaw = reactions(ir).KineticLaw; % Will be empty if no kinetic law parameters exist
    if ~isempty(kineticlaw)
        constantskl = kineticlaw.Parameters; % Will only fetch parameters unique to this kinetic law
        nkkl = length(constantskl);
        for j = 1:nkkl
            nk = nk + 1; % Add one more parameter
            kNames{nk,1} = constantskl(j).Name;
            k(nk,1) = constantskl(j).Value;
        end
    end
end

if verbose; fprintf('done.\n'); end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 2: Renaming Everything to Allow for Symbolic Handling %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if verbose; fprintf('Renaming variables...'); end
%% Convert compartment names to differentiable names
% The names to be used will be "co1x", "co2x" etc...
vSyms = sym(zeros(nv,1));
vNicestrs = cell(nv,1);

% We must be careful that the names we assign the variables are not already
% names being used by the model. This code checks if a potential name (i.e.
% "co1x" already exists. If it does, the code simply skips that number and
% tries the next one until it finds an unused name. Note that the "x" on
% the end of the variable names prevents string replace from seeing "sp1"
% in "sp10".

CurrentAttempt = 1; % The numerical appendix that will be tried
CurrentCompartment = 1; % Index through the compartments
AttemptIsGood = true; % Becomes false when a name already exists

while CurrentCompartment <= nv % Until every compartment
    CurrentName = sprintf('co%dx', CurrentAttempt);
    % Check to make sure a compartment does not have our systematic name
    for check = 1:nv
        % compartments except the one being renamed must not have 'co#x' as name
        if strcmp(CurrentName, vNames{check}) && CurrentCompartment ~= check
            AttemptIsGood = false;
        end
    end
    % Check species names
    for check = 1:nxu
        if strcmp(CurrentName, xuNames{check})
            AttemptIsGood = false;
        end
    end
    % Check parameter names
    for check = 1:nk
        if strcmp(CurrentName, kNames{check})
            AttemptIsGood = false;
        end
    end
    
    if AttemptIsGood % Change it and move on
        SimbioModel.Compartments(CurrentCompartment).rename(CurrentName);
        vSyms(CurrentCompartment) = sym(CurrentName);
        vNicestrs{CurrentCompartment} = CurrentName;
        CurrentCompartment = CurrentCompartment + 1;
        CurrentAttempt = CurrentAttempt + 1;
    else % It failed; try again with different number
        CurrentAttempt = CurrentAttempt + 1;
        AttemptIsGood = true;
    end
end

%% Convert species names to differentiable names
% The names will be "sp1x", "sp2x", etc...
xuSyms = sym(zeros(nxu,1));
xuNicestrs = cell(nxu,1);

% The important part here is to give every species a unique name,
% regardless of what compartment it is in. This way the compartments can be
% deleted without consequence.

CurrentAttempt = 1; % The numerical appendix that will be tried
CurrentSpecies = 1; % Index through the species
AttemptIsGood = true; % Becomes false when a name already exists

while CurrentSpecies <= nxu % Until every species
    CurrentName = sprintf('sp%dx', CurrentAttempt);
    % Check to make sure a compartment does not have our systematic name
    for check = 1:nv
        if strcmp(CurrentName, vNames{check})
            AttemptIsGood = false;
        end
    end
    % Check species names
    for check = 1:nxu
        if strcmp(CurrentName, xuNames{check}) && CurrentSpecies ~= check
            AttemptIsGood = false;
        end
    end
    % Check parameter names
    for check = 1:nk
        if strcmp(CurrentName, kNames{check})
            AttemptIsGood = false;
        end
    end
    
    if AttemptIsGood % Change it and move on
        SimbioModel.Species(CurrentSpecies).rename(CurrentName);
        xuSyms(CurrentSpecies) = sym(CurrentName);
        xuNicestrs{CurrentSpecies} = CurrentName;
        CurrentSpecies = CurrentSpecies + 1;
        CurrentAttempt = CurrentAttempt + 1;
    else % It failed; try again with different number
        CurrentAttempt = CurrentAttempt + 1;
        AttemptIsGood = true;
    end
end

%% Convert parameter names to things that won't confuse the symbolic toolbox
% The names will be "pa1x", "pa2x", etc...
kSyms = sym(zeros(nk,1));
kNicestrs = cell(nk,1);

CurrentAttempt = 1; % The numerical appendix that will be tried
CurrentParameter = 1; % Index through the name
AttemptIsGood = true; % Becomes false when a name already exists

while CurrentParameter <= nk % Until every parameter
    CurrentName = sprintf('pa%dx', CurrentAttempt);
    % Check to make sure a compartment does not have our systematic name
    for check = 1:nv
        if strcmp(CurrentName, vNames{check})
            AttemptIsGood = false;
        end
    end
    % Check species names
    for check = 1:nxu
        if strcmp(CurrentName, xuNames{check})
            AttemptIsGood = false;
        end
    end
    % Check parameter names
    for check = 1:nk
        if strcmp(CurrentName, kNames{check}) && CurrentParameter ~= check
            AttemptIsGood = false;
        end
    end
    
    if AttemptIsGood % Change it and move on
        if CurrentParameter <= nkm
            % It is a model parameter
            SimbioModel.Parameters(CurrentParameter).rename(CurrentName);
            
        else
            % This loop cycles through the reactions, finding how many
            % kinetic law parameters are in each. ind starts off as the
            % number of non-model parameters and is decremented by the
            % number of kinetic law parameters in each reaction until ind
            % is less than the kinetic law parameters defined in a specific
            % reaction. This means that ind now refers to the parameter
            % that needs to be changed.
            ind = CurrentParameter - nkm;
            ParameterNameNotChanged = true;
            CurrentReaction = 1;
            while ParameterNameNotChanged
                kineticlaw = reactions(CurrentReaction).KineticLaw; % Will be empty if this reaction does not use a kinetic law
                if ~isempty(kineticlaw)
                    nkkl = length(kineticlaw.Parameters);
                else
                    nkkl = 0;
                end
                if ind <= nkkl
                    kineticlaw.Parameters(ind).rename(CurrentName);
                    ParameterNameNotChanged = false;
                else
                    ind = ind - nkkl;
                    CurrentReaction = CurrentReaction + 1;
                end
            end
        end
        
        kSyms(CurrentParameter) = sym(CurrentName);
        kNicestrs{CurrentParameter} = CurrentName;
        CurrentParameter = CurrentParameter + 1;
        CurrentAttempt = CurrentAttempt + 1;
    else % It failed; try again with different number
        CurrentAttempt = CurrentAttempt + 1;
        AttemptIsGood = true;
    end
end

if verbose; fprintf('done.\n'); end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 3: Building the Diff Eqs %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if verbose; fprintf('Building the differential equations...'); end
%% Assemble rules expressions
rules = SimbioModel.Rules;
nRules = numel(rules);

% Initialize empty symbolic vector
targetStrs = cell(nRules,1);
valueStrs  = cell(nRules,1);

for iRule = 1:nRules
    rule = rules(iRule);
    
    if strcmpi(rule.RuleType, 'repeatedAssignment')
        % Split string rule into target and value
        splits = regexp(rule.Rule, '=', 'split');
        assert(numel(splits) == 2, 'KroneckerBio:simbio2Symbolic:InvalidRepeatedAssignment', 'Rule %i had an unparsible repeated assignment rule', iRule)
        targetStrs{iRule} = splits{1};
        valueStrs{iRule}  = splits{2};
    elseif strcmpi(rule.RuleType, 'initialAssignment')
        % Split string rule into target and value
        splits = regexp(rule.Rule, '=', 'split');
        assert(numel(splits) == 2, 'KroneckerBio:simbio2Symbolic:InvalidInitialAssignment', 'Rule %i had an unparsible repeated assignment rule', iRule)
        targetStrs{iRule} = splits{1};
        valueStrs{iRule}  = splits{2};
        
        
    else
        error('KroneckerBio:simbio2Symbolic:UnsupportedRuleType', 'Kronecker only supports repeatedAssignment rules, rule %i has type %s', iRule, rule.RuleType)
    end
end

%% Build up states and inputs
nx = nnz(~isu);
xNames = xuNames(~isu);
xSyms  = xuSyms(~isu);
xNicestrs = xuNicestrs(~isu);
x0      = sym(xu0(~isu)); % Default is no seed
vxInd   = vxuInd(~isu);

ns = 0;
sSyms = sym(zeros(0,1));
sNames = cell(0,1);
s = zeros(0,1);

nu = nnz(isu);
uNames = xuNames(isu);
uSyms  = xuSyms(isu);
uNicestrs = xuNicestrs(isu);
u = sym(xu0(isu)); % Default is no time varying inputs
vuInd   = vxuInd(isu);

nq = 0;
qSyms = sym(zeros(0,1));
qNames = cell(0,1);
q = zeros(0,1);

%% Build up rate string and stoichiometry
reactions = SimbioModel.Reactions;
speciesDimension = SimbioModel.getconfigset.CompileOptions.DefaultSpeciesDimension;

nSEntries = 0;
SEntries  = zeros(0,3);
rNames    = cell(nr,1);
rStrs     = cell(nr,1);

% Get each reaction and build stochiometry matrix
for i = 1:nr
    % Get reaction name
    rNames{i} = reactions(i).Name;
    
    % Get the reaction rate
    rStrs{i,1} = reactions(i).Reactionrate;
    
    % Build the stochiometry matrix
    reactants  = reactions(i).Reactants;
    products   = reactions(i).Products;
    stoichio   = reactions(i).Stoichiometry; % = [Reactants, Products] in order

    nReac      = numel(reactants);
    nProd      = numel(products);
    
    nAdd = nReac + nProd;
    
    % Add more room in vector if necessary
    currentLength = size(SEntries,1);
    if nSEntries + nAdd > currentLength
        addlength = max(currentLength, 1);
        SEntries = [SEntries; zeros(addlength,3)];
    end
    
    for j = 1:nReac
        reactant   = reactants(j).Name;
        ind    = find(strcmp(xuNicestrs, reactant));
        
        nSEntries = nSEntries + 1;
        SEntries(nSEntries,1) = ind;
        SEntries(nSEntries,2) = i;
        if strcmp(speciesDimension, 'substance')
            % Both stoichiometry and species are in amount
            SEntries(nSEntries,3) = stoichio(j);
        else % speciesDimension == 'concentration'
            % Stoichiometry is in concentration, reactions are in amount
            SEntries(nSEntries,3) = stoichio(j) / v(vxuInd(ind));
        end
    end
    
    for j = 1:nProd
        reactant   = products(j).Name;
        ind    = find(strcmp(xuNicestrs, reactant));

        nSEntries = nSEntries + 1;
        SEntries(nSEntries,1) = ind;
        SEntries(nSEntries,2) = i;
        if strcmp(speciesDimension, 'substance')
            % Both stoichiometry and species are in amount
            SEntries(nSEntries,3) = stoichio(j+nReac);
        else % speciesDimension == 'concentration'
            % Stoichiometry is in concentration, reactions are in amount
            SEntries(nSEntries,3) = stoichio(j+nReac) / v(vxuInd(ind));
        end
    end
end

% Delete compartment prefixes "co1x."
for iv = 1:nv
    %'.' is a special character in regexprep, use '\.' to really mean '.'
    rStrs = regexprep(rStrs, [vNicestrs{iv} '\.'], '');
end

% Symbolically evaluate r
r = sym(rStrs);

% Assemble stoichiometry matrix
S = sparse(SEntries(1:nSEntries,1), SEntries(1:nSEntries,2), SEntries(1:nSEntries,3), nxu, nr);
Su = S(isu,:);
S = S(~isu,:);

%% Convert reactions and rules to symbolics
% % Delete compartment prefixes "co1x."
% for iv = 1:nv
%     %'.' is a special character in regexprep, use '\.' to really mean '.'
%     rStrs = regexprep(rStrs, [vNicestrs{iv} '\.'], '');
% end
% 
% % Replace string variables with symbolics
% for iv = 1:nv
%     rStrs = regexprep(rStrs, vNicestrs{iv}, ['sym(''' vNicestrs{iv} ''')']);
%     valueStrs = regexprep(valueStrs, vNicestrs{iv}, ['sym(''' vNicestrs{iv} ''')']);
% end
% for ix = 1:nx
%     rStrs = regexprep(rStrs, xuNicestrs{ix}, ['sym(''' xuNicestrs{ix} ''')']);
%     valueStrs = regexprep(valueStrs, xuNicestrs{ix}, ['sym(''' xuNicestrs{ix} ''')']);
% end
% for ik = 1:nk
%     rStrs = regexprep(rStrs, kNicestrs{ik}, ['sym(''' kNicestrs{ik} ''')']);
%     valueStrs = regexprep(valueStrs, kNicestrs{ik}, ['sym(''' kNicestrs{ik} ''')']);
% end
% for iRule = 1:nRules
%     rStrs = regexprep(rStrs, targetStrs{iRule}, ['sym(''' targetStrs{iRule} ''')']);
%     valueStrs = regexprep(valueStrs, targetStrs{iRule}, ['sym(''' targetStrs{iRule} ''')']);
% end
% 
% % Create symbolic reaction rates
% r = repmat(sym('empty'), nr,1);
% for ir = 1:nr
%     r(ir) = eval(rStrs{ir});
% end

% Create symbolic rules
targetSyms = sym(zeros(nRules,1));
valueSyms  = sym(zeros(nRules,1));
for iRule = 1:nRules
    targetSyms(iRule) = sym(targetStrs{iRule});
    valueSyms(iRule)  = eval(valueStrs{iRule});
end

%% Replace reaction rates with symbolics
% This may require up to nRules iterations of substitution
for iRule = 1:nRules
    r = subs(r, targetSyms, valueSyms, 0);
end

% Delete rule parameters
found = lookup(targetSyms, kSyms);
kSyms(found(found ~= 0)) = [];
kNames(found(found ~= 0)) = [];
k(found(found ~= 0)) = [];
nk = numel(kSyms);

% Convert all rule species to inputs
found = lookup(targetSyms, xuSyms);

if verbose; fprintf('done.\n'); end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Part 4: Build Symbolic Model %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

SymModel.Type       = 'Model.SymbolicReactions';
SymModel.Name       = name;

SymModel.nv         = nv;
SymModel.nk         = nk;
SymModel.ns         = ns;
SymModel.nq         = nq;
SymModel.nu         = nu;
SymModel.nx         = nx;
SymModel.nr         = nr;

SymModel.vSyms      = vSyms;
SymModel.vNames     = vNames;
SymModel.dv         = zeros(nv,1) + 3; % TODO: from units
SymModel.v          = v;

SymModel.kSyms      = kSyms;
SymModel.kNames     = kNames;
SymModel.k          = k;

SymModel.sSyms      = sSyms;
SymModel.sNames     = sNames;
SymModel.s          = s;

SymModel.qSyms      = qSyms;
SymModel.qNames     = qNames;
SymModel.q          = q;

SymModel.uSyms      = uSyms;
SymModel.uNames     = uNames;
SymModel.vuInd      = vuInd;
SymModel.u          = u;

SymModel.xSyms      = xSyms;
SymModel.xNames     = xNames;
SymModel.vxInd      = vxInd;
SymModel.x0         = x0;

SymModel.rNames     = rNames;
SymModel.r          = r;
SymModel.S          = S;
SymModel.Su         = Su;
