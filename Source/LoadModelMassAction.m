function m = LoadModelMassAction(files)
%LoadModelMassAction Load a model from the standard Kronecker model file
%   format
%
%   m = LoadModelMassAction(filenames)
%
%   Inputs:
%   files: [ cell vector of strings | string ]
%       The names of the files to be loaded
%
%   Outputs:
%   m: [ Model.MassActionKronecker scalar ]
%       The mass action Kronecker model constructed from the supplied files
%
%   The files are read in the order in which they appear in the files
%   vector.
%
%   If compartments, species, outputs, or parameters appear multiple times
%   throughout the files, the last instance by that name is the one that
%   will define that component's properties. All others by that same name
%   will be silently overwritten.

% (c) 2013 David R Hagen & Bruce Tidor
% This work is released under the MIT license.

%% Initialize the model
m = InitializeModel('');

% Standardize files a cell vector of strings
if ischar(files)
    files = {files};
end
nFiles = numel(files);

% Check that files exist
for i = 1:nFiles
    assert(exist(files{i}, 'file') == 2, 'KroneckerBio:LoadModelMassAction:FileNotFound', 'File %s was not found', files{i})
end

%% Loop over each file
for iFile = 1:nFiles
    % Open file
    fid = fopen(files{iFile});
    
    % Initialize
    mode = 0;
    lineNumber = 0;
    
    % Loop over all lines in code
    while true % break on -1
        % Get next line
        line = fgetl(fid);
        lineNumber = lineNumber + 1;
        
        % Break if end of file is encountered
        if line == -1
            break
        end
        
        % Skip if line is empty or begins with a "#"
        if isempty(line) || ~isempty(regexp(line, '^\s*#|^\s*$', 'once'))
            continue
        end
        
        % Check if mode switching line is encountered
        % First character is a "%"
        isSwitchMode = ~isempty(regexp(line, '^\s*%', 'once'));
        
        if isSwitchMode
            [match payload] = regexp(line, '^\s*%*\s*\w*', 'match', 'split', 'once');
            payload = payload{2}; % Only want the end, not the starting empty string
            match = regexp(match, '\w*', 'match');

            if strcmpi(match, 'compartments')
                % Switch mode
                mode = 1;
                
                % Extract model name
                modelName = regexp(payload, '".*"|[^\s]*', 'match', 'once');
                modelName = regexp(modelName, '[^"]*', 'match', 'once'); % Strip quotes
                m = RenameModel(m, modelName);
            elseif strcmpi(match, 'inputs')
                % Switch mode
                mode = 2;
                
                % Extract default compartment from payload
                defaultCompartment = regexp(payload, '".*"|[^.,\s]*', 'match');
                assert(numel(defaultCompartment) <= 1, 'KroneckerBio:LoadModelMassAction:MultipleSpeciesCompartments', 'Line %i in %s specified multiple compartments for a single section of species; a species section can have at most one default compartment: %s', lineNumber, files{iFile}, line)
                
                % Standardize compartment as a string
                if isempty(defaultCompartment)
                    defaultCompartment = '';
                else
                    defaultCompartment = defaultCompartment{1};
                end
            elseif strcmpi(match, 'seeds')
                % Switch mode
                mode = 3;
            elseif strcmpi(match, 'states')
                % Switch mode
                mode = 4;
                                
                % Extract default compartment from payload
                defaultCompartment = regexp(payload, '".*"|[^.,\s]*', 'match');
                assert(numel(defaultCompartment) <= 1, 'KroneckerBio:LoadModelMassAction:MultipleSpeciesCompartments', 'Line %i in %s specified multiple compartments for a single section of species; a species section can have at most one default compartment: %s', lineNumber, files{iFile}, line)
                
                % Standardize compartment as a string
                if isempty(defaultCompartment)
                    defaultCompartment = '';
                else
                    defaultCompartment = defaultCompartment{1};
                end

            elseif strcmpi(match, 'outputs')
                % Switch mode
                mode = 5;
            elseif strcmpi(match, 'parameters')
                % Switch mode
                mode = 6;
            elseif strcmpi(match, 'reactions')
                % Switch mode
                mode = 7;

                % Extract default compartments from payload
                defaultCompartment = regexp(payload, '".*"|[^.,\s]*', 'match');
            else
                error('KroneckerBio:LoadModelMassAction:UnrecognizedSectionHeader', 'Line %i in %s had an unrecognized section header: %s', lineNumber, files{iFile}, line)
            end
        else
            % Process entries
            if mode == 1
                % Compartments
                tokens = vec(regexp(line, ',|".*"|[^\s,]*','match'));
                assert(numel(tokens) >= 3, 'KroneckerBio:LoadModelMassAction:InsufficientCompartmentInformation', 'Line %i in %s does not provide the name, dimension, and size required for a compartment: %s', lineNumber, files{iFile}, line)
                
                % Strip quotes
                for iTok = 1:numel(tokens)
                    tokens{iTok} = regexp(tokens{iTok}, '[^"]*', 'match', 'once');
                end
                
                % Extract name
                assert(~isempty(regexp(tokens{1}, '^[^\s,.]*$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidCompartmentName', 'Line %i in %s has an invalid compartment name: %s', lineNumber, files{iFile}, line)
                name = tokens{1};
                
                % Extract dimension
                assert(~isempty(regexp(tokens{2}, '^0|1|2|3$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidCompartmentDimension', 'Line %i in %s has an invalid compartment dimension: %s', lineNumber, files{iFile}, line)
                dim = str2double(tokens{2});
                
                % Second token is value
                assert(~isempty(regexp(tokens{3}, '^[+]?([0-9]*\.)?[0-9]+([eE][-+]?[0-9]+)?$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidCompartmentSize', 'Line %i in %s has an invalid compartment size: %s', lineNumber, files{iFile}, line)
                value = eval(tokens{3});
                
                % Add compartment
                m = AddCompartment(m, name, dim, value);
            elseif mode == 2
                % Inputs
                tokens = vec(regexp(line, ',|".*"|[^\s,]*','match'));
                
                % Strip quotes
                for iTok = 1:numel(tokens)
                    tokens{iTok} = regexp(tokens{iTok}, '[^"]*', 'match', 'once');
                end
                
                % Extract name
                assert(~isempty(regexp(tokens{1}, '^[^\s,]*\.?[^\s,]*$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidSpeciesName', 'Line %i in %s has an invalid species name: %s', lineNumber, files{iFile}, line)
                name = tokens{1};
                if isempty(regexp(name, '\.', 'once'))
                    % Compartment is defualt compartment
                    assert(~isempty(defaultCompartment), 'KroneckerBio:LoadModelMassAction:SpeciesWithNoCompartment', 'Line %i in %s has a species that is not associated with a compartment: %s', lineNumber, files{iFile}, line)
                    compartment = defaultCompartment;
                else
                    % Compartment is specified within name
                    compartment = regexp(name, '^[^.]*', 'match', 'once');
                    name = regexp(name, '[^.]*$', 'match', 'once');
                end
                
                % Extract expressions into seperate cells
                func = cell(0,1);
                nVal = 0;
                for i = 2:numel(tokens)
                    assert(~strcmp(tokens{i}, ','), 'KroneckerBio:LoadModelMassAction:UnexpectedToken', 'Line %i in %s has an unexpected comma: %s', lineNumber, files{iFile}, line)
                    
                    % Stop if this is the last token or the next token is
                    % not a comma
                    if i == numel(tokens) || ~strcmp(tokens{i+1}, ',')
                        func = tokens(2:i);
                        nVal = numel(func);
                        break
                    else
                        % Remove the comma and continue extraction
                        tokens(i+1) = [];
                    end
                end
                
                % Process parameters
                parameters = zeros(0,1);
                if numel(tokens) > 1+nVal
                    % There are parameters
                    for i = 2+nVal:numel(tokens)
                        assert(~strcmp(tokens{i}, ','), 'KroneckerBio:LoadModelMassAction:UnexpectedToken', 'Line %i in %s has an unexpected comma: %s', lineNumber, files{iFile}, line)
                        % Stop if this is the last token or the next token is
                        % not a comma
                        if i == numel(tokens) || strcmp(tokens{i}, ',')
                            parameters = tokens(2+nVal:i);
                            break
                        else
                            % Remove the comma and continue extraction
                            tokens(i+1) = [];
                        end
                    end
                    parameters = str2double(parameters);
                end
                
                % Add Input
                m = AddInput(m, name, compartment, func, parameters);
            elseif mode == 3
                % Seeds
                tokens = vec(regexp(line, ',|".*"|[^\s,]*','match'));
                
                % Strip quotes
                for iTok = 1:numel(tokens)
                    tokens{iTok} = regexp(tokens{iTok}, '[^"]*', 'match', 'once');
                end
                
                % Extract name
                assert(~isempty(regexp(tokens{1}, '^[^\s,.]*$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidParameterName', 'Line %i in %s has an invalid seed name: %s', lineNumber, files{iFile}, line)
                name = tokens{1};
                
                % Second token is the number
                value = eval(tokens{2});
                
                % Add seed
                m = AddSeed(m, name, value);
            elseif mode == 4
                % States
                tokens = vec(regexp(line, '".*"|[^\s,]*','match'));
                
                % Strip quotes
                for iTok = 1:numel(tokens)
                    tokens{iTok} = regexp(tokens{iTok}, '[^"]*', 'match', 'once');
                end
                
                % Extract name
                assert(~isempty(regexp(tokens{1}, '^[^\s,]*\.?[^\s,]*$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidName', 'Line %i in %s has an invalid species name: %s', lineNumber, files{iFile}, line)
                name = tokens{1};
                tokens = tokens(2:end);
                if isempty(regexp(name, '\.', 'once'))
                    % Compartment is defualt compartment
                    assert(~isempty(defaultCompartment), 'KroneckerBio:LoadModelMassAction:SpeciesWithNoCompartment', 'Line %i in %s has a species that is not associated with a compartment: %s', lineNumber, files{iFile}, line)
                    compartment = defaultCompartment;
                else
                    % Compartment is specified within name
                    compartment = regexp(name, '^[^.]*', 'match', 'once');
                    name = regexp(name, '[^.]*$', 'match', 'once');
                end
                
                % Process seeds
                n_seeds = numel(tokens);
                seeds = cell(n_seeds,2);
                for i_seed = 1:n_seeds
                    % Split between the equal sign
                    elements = regexp(tokens{i_seed}, '=', 'split');
                    assert(numel(elements) <= 2, 'KroneckerBio:LoadModelMassAction:InvalidExpression', 'Line %i in %s has more than one equal sign in an expression: %s', lineNumber, files{iFile}, line)
                    
                    if numel(elements) == 2
                        % It is a seed and a modifier
                        seeds(i_seed,:) = {elements{1}, str2double(elements{2})};
                    elseif numel(elements) == 1 && ~isempty(regexp(tokens{1}, '^\d', 'once'))
                        % It is a constitutive initial value
                        seeds(i_seed,:) = {'',  eval(elements{1})};
                    else
                        % It is a single seed
                        seeds(i_seed,:) = {elements{1}, 1};
                    end
                end
                
                % Add State
                m = AddState(m, name, compartment, seeds);
            elseif mode == 5
                % Outputs
                tokens = vec(regexp(line, ',|".*"|[^\s,]*','match'));
                
                % Strip quotes
                for iTok = 1:numel(tokens)
                    tokens{iTok} = regexp(tokens{iTok}, '[^"]*', 'match', 'once');
                end
                
                % Extract name
                assert(~isempty(regexp(tokens{1}, '^[^\s,.]*$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidName', 'Line %i in %s has an invalid output name: %s', lineNumber, files{iFile}, line)
                name = tokens{1};
                tokens = tokens(2:end);
                
                % Process seeds
                n_expr = numel(tokens);
                expressions = cell(n_expr,2);
                for i_expr = 1:n_expr
                    % Split between the equal sign
                    elements = regexp(tokens{i_expr}, '=', 'split');
                    assert(numel(elements) <= 2, 'KroneckerBio:LoadModelMassAction:InvalidExpression', 'Line %i in %s has more than one equal sign in an expression: %s', lineNumber, files{iFile}, line)
                    
                    if numel(elements) == 2
                        % It is a expression and a modifier
                        expressions(i_expr,:) = {elements{1}, str2double(elements{2})};
                    elseif numel(elements) == 1 && ~isempty(regexp(tokens{1}, '^\d', 'once'))
                        % It is a constitutive value
                        expressions(i_expr,:) = {'',  eval(elements{1})};
                    else
                        % It is a single expression
                        expressions(i_expr,:) = {elements{1}, 1};
                    end
                end
                
                % Add output
                m = AddOutput(m, name, expressions);
            elseif mode == 6
                % Parameters
                tokens = vec(regexp(line, ',|".*"|[^\s,]*','match'));
                
                % Strip quotes
                for iTok = 1:numel(tokens)
                    tokens{iTok} = regexp(tokens{iTok}, '[^"]*', 'match', 'once');
                end
                
                % Extract parameter name
                assert(~isempty(regexp(tokens{1}, '^[^\s,.]*$', 'once')), 'KroneckerBio:LoadModelMassAction:InvalidName', 'Line %i in %s has an invalid compartment name: %s', lineNumber, files{iFile}, line)
                name = tokens{1};
                
                % Second token is value
                try
                    value = eval(tokens{2});
                catch e
                    error('KroneckerBio:LoadModelMassAction:InvalidValue', ...
                        'parameter "%s" with value "%s" is not a valid parameter value', name, tokens{2});
                end
                % Add parameter
                m = AddParameter(m, name, value);
            elseif mode == 7
                % Reactions
                tokens = vec(regexp(line, ',|".*"|[^\s,]*','match'));
                
                % Strip quotes
                for iTok = 1:numel(tokens)
                    tokens{iTok} = regexp(tokens{iTok}, '[^"]*', 'match', 'once');
                end
                
                if ~strcmp(tokens{1}, ',')
                    % Add empty reverse parameter if not specified
                    if numel(tokens) < 6
                        tokens  = [tokens; {''}];
                    end
                    
                    parameters = cell(2,2);
                    for i = 1:size(parameters,1)
                        % Split between the equal sign
                        elements = regexp(tokens{i+4}, '=', 'split');
                        assert(numel(elements) <= 2, 'KroneckerBio:LoadModelMassAction:InvalidExpression', 'Line %i in %s has more than one equal sign in an expression: %s', lineNumber, files{iFile}, line)
                        
                        if numel(elements) == 2
                            % It is a parameter and a modifier
                            parameters(i,:) = {elements{1}, eval(elements{2})};
                        else
                            % It is a single parameter
                            parameters(i,:) = {elements{1}, 1};
                        end
                    end
                    
                    % This is a normal line
                    m = AddReaction(m, tokens(7:end), defaultCompartment, tokens{1}, tokens{2}, tokens{3}, tokens{4}, parameters(1,:), parameters(2,:));
                else
                    % Split between the equal sign
                    parameter = regexp(tokens{end}, '=', 'split');
                    assert(numel(parameter) <= 2, 'KroneckerBio:LoadModelMassAction:InvalidExpression', 'Line %i in %s has more than one equal sign in an expression: %s', lineNumber, files{iFile}, line)
                    
                    if numel(parameter) == 2
                        % It is a parameter and a modifier
                        parameter = {parameter{1}, eval(parameter{2})};
                    else
                        % It is a single parameter
                        parameter = {parameter{1}, 1};
                    end
                    
                    % This is the special syntax for a multi-product line
                    m = AddLargeSizeReaction(m, [], defaultCompartment, tokens(2:3), tokens(4:end-1), parameter);
                end
            else
                error('KroneckerBio:LoadModelMassAction:SectionNotSpecified', 'Line %i in %s occurs before any section header: %s', lineNumber, files{iFile}, line)
            end
        end
    end
    
    % Close the model file
    fclose(fid);
end

%% Finalize Model
m = FinalizeModel(m);
