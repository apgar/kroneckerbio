function [varargout] = SimulateCurvature(m, con, opts)
%SimulateCurvature Integrate the second-order sensitivities 
%   of every species with respect to every parameter over all time in the
%   mass action kinetics framework
%   
%   Mathematically: d2x/dT2 = Integral(df/dx * d2x/dT2 +
%                                      2 * d2f/dTx * dx/dT +
%                                      (d2f/dx2 * dx/dT) * dx/dT +
%                                      d2f/dT2, t=0:tF)
%   
%   sim = SimulateCurvature(m, con, tGet, opts)
%   
%   Inputs
%   m: [ model struct scalar ]
%       The KroneckerBio model that will be simulated
%   con: [ experiment struct vector ]
%       The experimental conditions under which the model will be simulated
%   opts: [ options struct scalar {} ]
%       .UseModelSeeds [ logical scalar {false} ]
%           Indicates that the model's initial conditions should be used
%           instead of those of the experimental conditions
%       .UseModelInputs [ logical scalar {false} ]
%           Indicates that the model's inputs should be used instead of
%           those of the experimental conditions
%       .UseParams [ logical vector nk | positive integer vector {1:nk} ]
%           Indicates the kinetic parameters whose sensitivities are
%           desired
%       .UseSeeds [ logical matrix nx by nCon | logical vector nx |
%                 positive integer vector {[]} ]
%           Indicates the initial conditions of the state species whose
%           sensitivites are desired
%       .UseControls [ cell vector nCon of logical vectors or positive 
%                      integer vectors | logical vector nq | positive 
%                      integer vector {[]} ]
%           Indicates the input control parameters whose sensitivites are
%           desired
%       .RelTol [ nonnegative scalar {1e-6} ]
%           Relative tolerance of the integration
%       .AbsTol [ cell vector of nonnegative vectors | nonnegative vector |
%                 nonegative scalar {1e-9} ]
%           Absolute tolerance of the integration. If a cell vector is
%           provided, a different AbsTol will be used for each experiment.
%       .Verbose [ nonnegative integer scalar {1} ]
%           Bigger number displays more progress information
%
%   Outputs
%   SimulateCurvature(m, con, tGet, opts)
%   	Plots the second-order sensitivities under each condition
%
%   sim = SimulateCurvature(m, con, tGet, opts)
%   	A vector of structures with each entry being the simulation
%       under one of the conditions.
%       .t [ sorted nonnegative row vector ]
%           Timepoints chosen by the ode solver
%       .y [ handle @(t,y) returns matrix numel(y) by numel(t) ]
%           This function handle evaluates some outputs y of the system at
%           some particular time points t. The user may exclude y, in which
%           case all outputs are returned.
%       .x [ handle @(t,x) returns matrix numel(x) by numel(t) ]
%           This function handle evaluates some states x of the system at
%           some particular time points t. The user may exclude x, in which
%           case all states are returned.
%       .dydT [ handle @(t,y) returns matrix numel(y)*nT by numel(t) ]
%           This function handle evaluates the sensitivity of some outputs
%           y to the active parameters of the system at some particular
%           time points t. The user may exclude y, in which case all
%           outputs are returned.
%       .dxdT [ handle @(t,x) returns matrix numel(x) by numel(t) ]
%           This function handle evaluates the sensitivity of some states
%           x to the active parameters of the system at some particular
%           time points t. The user may exclude x, in which case all
%           states are returned.
%       .d2ydT2 [ handle @(t,y) returns matrix numel(y)*nT*nT by numel(t) ]
%           This function handle evaluates the curvature of some outputs
%           y to the active parameters of the system at some particular
%           time points t. The user may exclude y, in which case all
%           outputs are returned.
%       .d2xdT2 [ matrix nx by numel(tGet) ]
%           This function handle evaluates the curvature of some states
%           x to the active parameters of the system at some particular
%           time points t. The user may exclude x, in which case all
%           states are returned.
%       .sol [ struct scalar ]
%           The discrete integrator solution to the system

% (c) 2013 David R Hagen & Bruce Tidor
% This work is released under the MIT license.

%% Work-up
% Clean up inputs
if nargin < 3
    opts = [];
end

assert(nargin >= 2, 'KroneckerBio:SimulateCurvatureSelect:TooFewInputs', 'SimulateSensitivitySelect requires at least 2 input arguments')
assert(isscalar(m), 'KroneckerBio:SimulateCurvatureSelect:MoreThanOneModel', 'The model structure must be scalar')

% Default options
defaultOpts.Verbose        = 1;

defaultOpts.RelTol         = NaN;
defaultOpts.AbsTol         = NaN;
defaultOpts.UseModelSeeds  = false;
defaultOpts.UseModelInputs = false;

defaultOpts.UseParams      = 1:m.nk;
defaultOpts.UseSeeds       = [];
defaultOpts.UseControls    = [];

opts = mergestruct(defaultOpts, opts);

verbose = logical(opts.Verbose);
opts.Verbose = max(opts.Verbose-1,0);

% Constants
nx = m.nx;
ny = m.ny;
nk = m.nk;
nCon = numel(con);

% Ensure UseParams is logical vector
[opts.UseParams, nTk] = fixUseParams(opts.UseParams, nk);

% Ensure UseSeeds is a logical matrix
[opts.UseSeeds, nTx] = fixUseSeeds(opts.UseSeeds, opts.UseModelSeeds, nx, nCon);

% Ensure UseControls is a cell vector of logical vectors
[opts.UseControls, nTq] = fixUseControls(opts.UseControls, opts.UseModelInputs, nCon, m.nq, cat(1,con.nq));

nT = nTk + nTx + nTq;

% Refresh conditions
con = refreshCon(m, con);

% RelTol
opts.RelTol = fixRelTol(opts.RelTol);

% Fix AbsTol to be a cell array of vectors appropriate to the problem
opts.AbsTol = fixAbsTol(opts.AbsTol, 3, false(nCon,1), nx, nCon, false, opts.UseModelSeeds, opts.UseModelInputs, opts.UseParams, opts.UseSeeds, opts.UseControls);

%% Run integration for each experiment
sim = emptystruct(nCon, 'Type', 'Name', 't', 'y', 'x', 'dydT', 'dxdT', 'd2ydT2', 'd2xdT2', 'sol');

for iCon = 1:nCon
    % Modify opts structure
    intOpts = opts;
    intOpts.AbsTol = opts.AbsTol{iCon};
    
    % If opts.UseModelSeeds is false, the number of variables can change
    if opts.UseModelSeeds
        UseSeeds_i = opts.UseSeeds;
    else
        UseSeeds_i = opts.UseSeeds(:,iCon);
    end
    intOpts.UseSeeds = UseSeeds_i;
    inTs = nnz(UseSeeds_i);
    
    % If opts.UseModelInputs is false, the number of variables can change
    if opts.UseModelInputs
        UseControls_i = opts.UseControls{1};
    else
        UseControls_i = opts.UseControls{iCon};
    end
    intOpts.UseControls = UseControls_i;
    inTq = nnz(UseControls_i);
    
    inT = nTk + inTs + inTq;
    
    % Integrate [x; dx/dT; d2x/dT2] over time
    if verbose; fprintf(['Integrating curvature for ' con(iCon).Name '...']); end
    sol = integrateCurv(m, con(iCon), intOpts);
    if verbose; fprintf('done.\n'); end
    
    % Store results
    sim(iCon).Type   = 'Simulation.Sensitivity';
    sim(iCon).Name   = [m.Name ' in ' con(iCon).Name];
    sim(iCon).t      = sol.x;
    sim(iCon).y      = @(t, varargin)evaluateOutputs(sol, t, varargin{:});
    sim(iCon).x      = @(t, varargin)evaluateStates(sol, t, varargin{:});
    sim(iCon).dydT   = @(t, varargin)evaluateOutputSensitivities(sol, t, varargin{:});
    sim(iCon).dxdT   = @(t, varargin)evaluateStateSensitivities(sol, t, varargin{:});
    sim(iCon).d2ydT2 = @(t, varargin)evaluateOutputCurvatures(sol, t, varargin{:});
    sim(iCon).d2xdT2 = @(t, varargin)evaluateStateCurvatures(sol, t, varargin{:});
    sim(iCon).sol    = sol;
end

%% Work-down
if nargout == 0
    % Draw each result
    for iCon = 1:nCon
        subplot(nCon,1,iCon)
        plotCurvatureExperiment(m, sim(iCon), 'Linewidth', 2);
    end
else
    varargout{1} = sim;
end

% End of function
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Evaluation functions %%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function val = evaluateOutputs(sol, t, ind)
nt = numel(t);

if nargin < 3
    val = sol.C1 * deval(sol, t) + sol.C2 * sol.u(t) + repmat(sol.c, 1,nt);
else
    val = sol.C1(ind,:) * deval(sol,t) + sol.C2(ind,:) * sol.u(t) + repmat(sol.c(ind,:), 1,nt);
end
end

function val = evaluateStates(sol, t, ind)
if nargin < 3
    val = deval(sol, t);
else
    val = deval(sol, t, ind);
end
end

function val = evaluateOutputSensitivities(sol, t, ind)
nx = size(sol.C1,2);
ny = size(sol.C1,1);
nT = (-nx+sqrt(nx^2-4*nx*(nx-size(sol.y,1))))/(2*nx);
nt = numel(t);

if nargin < 3
    val = deval(sol, t, nx+1:nx+nx*nT); % xT_t
    val = reshape(val, nx,nT*nt); % x_Tt
    val = sol.C1*val; % y_Tt
    val = reshape(val, ny*nT,nt); % yT_t
else
    val = deval(sol, t, nx+1:nx+nx*nT); % xT_t
    val = reshape(val, nx,nT*nt); % x_Tt
    val = sol.C1(ind,:)*val; % y_Tt
    val = reshape(val, nnz(ind)*nT,nt); % yT_t
end
end

function val = evaluateStateSensitivities(sol, t, ind)
nx = size(sol.C1,2);
nT = (-nx+sqrt(nx^2-4*nx*(nx-size(sol.y,1))))/(2*nx);
nt = numel(t);

if nargin < 3
    val = deval(sol, t, nx+1:nx+nx*nT); % xT_t
else
    val = deval(sol, t, nx+1:nx+nx*nT); % xT_t
    val = reshape(val, nx,nT*nt); % x_Tt
    val = val(ind,:); % x_Tt chopped out rows
    val = reshape(val, nnz(ind)*nT,nt); % xT_t
end
end

function val = evaluateOutputCurvatures(sol, t, ind)
nx = size(sol.C1,2);
ny = size(sol.C1,1);
nT = (-nx+sqrt(nx^2-4*nx*(nx-size(sol.y,1))))/(2*nx);
nt = numel(t);

if nargin < 3
    val = deval(sol, t, nx+nx*nT+1:nx+nx*nT+nx*nT*nT); % xTT_t
    val = reshape(val, nx,nT*nT*nt); % x_TTt
    val = sol.C1*val; % y_TTt
    val = reshape(val, ny*nT*nT,nt); % yTT_t
else
    val = deval(sol, t, nx+nx*nT+1:nx+nx*nT+nx*nT*nT); % xTT_t
    val = reshape(val, nx,nT*nT*nt); % x_TTt
    val = sol.C1(ind,:)*val; % y_TTt
    val = reshape(val, nnz(ind)*nT*nT,nt); % yTT_t
end
end

function val = evaluateStateCurvatures(sol, t, ind)
nx = size(sol.C1,2);
nT = (-nx+sqrt(nx^2-4*nx*(nx-size(sol.y,1))))/(2*nx);
nt = numel(t);

if nargin < 3
    val = deval(sol, t, nx+nx*nT+1:nx+nx*nT+nx*nT*nT); % xTT_t
else
    val = deval(sol, t, nx+nx*nT+1:nx+nx*nT+nx*nT*nT); % xTT_t
    val = reshape(val, nx,nT*nT*nt); % x_TTt
    val = val(ind,:); % x_TTt chopped out rows
    val = reshape(val, nnz(ind)*nT*nT,nt); % xTT_t
end
end
end