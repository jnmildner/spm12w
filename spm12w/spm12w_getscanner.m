function p = spm12w_getscanner(varargin)
% spm12w_getscanner(epifiles, params)
% Input
% -----
% epifiles : a cell array of paths/filenames for epi files to derive scanning
%            parameters from.
%
% p        : A structure of parameters (i.e., p, glm, etc.). 
%
% Takes a cell array of epifile names and paths and a parameters structure 
% and determines scanning parameters from the epifiles (i.e., tr, nvols, nslice
% and nses). 
%
% It is unclear if this method will continue to work with non
% dartmouth files. It depends on what is contained in the nifti header.
% If it fails, we can start adding variables back to the params file for the
% user to set manually. 
%
% Examples:
%
%   >> spm12w_getscanner({'./raw/s01/epi_r01.nii.gz', ...
%                         './raw/s01/epi_r02.nii.gz'}, p)
%
% # spm12w was developed by the Wagner, Heatherton & Kelley Labs
% # Author: Dylan Wagner | Created: November, 2014 | Updated: March, 2017
% =======1=========2=========3=========4=========5=========6=========7=========8

args_defaults = struct('epifiles','', 'p','');
args = spm12w_args('nargs',4, 'defaults', args_defaults, 'arguments', varargin);

% Assign args.p to p (as eventually we want to return p)
p = args.p;

% Determine scanning parameters from epi files
msg = sprintf(['Loading scanning parameters from epi ' ...
                   'files for subject: %s'], p.sid);
spm12w_logger('msg',p.niceline, 'level',p.loglevel)
spm12w_logger('msg',msg, 'level',p.loglevel);

% Figure out dir and extension of epifile
[epidir, ~, epiext] = fileparts(args.epifiles{1});

% Figure out parameters
tr = [];
nvols = [];
nslice = [];
for ses_i = 1:length(args.epifiles)
    % Check if gziped otherwise assume regular nifti.
    if strcmp(epiext, '.gz')
        % As spm doesn't support gz, unzip to a tempdir, load vol
        tmpdir = tempname(epidir);
        mkdir(tmpdir)
        outfile = char(gunzip(args.epifiles(ses_i),tmpdir));
    else
        outfile = epifiles{ses_i};
    end
    niihdr = spm_vol(outfile);
    % In some cases the nifti hdr does not contain TR information or the user 
    % wants to override the TR in the nifti header due to an improper header
    % Thus we give priority to manually specified TR, followed by the TR 
    % in the niftiheader. Note that because the private info in niihdr
    % is a nifti object, we can't use isfield and have to do this hack.
    if isfield(p,'tr')
        tr(ses_i) = p.tr; 
    elseif ~isempty(niihdr(1).private.timing)
        tr(ses_i) = niihdr(1).private.timing.tspace; %set tr
    else
        spm12w_logger('msg',['[EXCEPTION] No TR information present in ' ... 
                  'nifti hdr (i.e., private.timing.tspace). Please manually ' ...
                  'specify the TR in your parameters file. Aborting...'],...
                  'level',p.loglevel)
        diary off
        error('No TR information present in nifti header...')
    end
    nvols(ses_i) = length(niihdr); %number of vols in niiheader.
    nslice(ses_i) = min(niihdr(1).dim); %assume smallest dimension is slices.
    % now cleanup temp zip dir
    if strcmp(epiext, '.gz')
        delete(outfile)
        rmdir(tmpdir)
    end
    spm12w_logger('msg', sprintf('Run: %d, tr=%.2f, nvols=%d, nslice=%d', ...
                  ses_i, tr(ses_i), nvols(ses_i), nslice(ses_i)), ...
                  'level', p.loglevel)
end

% Verify nslice and give excepetion if fail check
if length(unique(nslice)) == 1
    % Assign scanner variables
    p.nslice = unique(nslice);
    p.nses   = length(args.epifiles); % should always work if files are well named
    p.nvols  = nvols;
    p.tr     = tr;
    % Determine slice order 
    % Get potential json name, assumes all runs have same sliceorder!
    [epidir,jname,~] = fileparts(args.epifiles{1});
    jname = strtok(jname,'.'); % in case fileparts left .nii ext
    jpath = fullfile(epidir,[jname,'.json']);
    p.sliceorder=[];
    if exist(jpath,'file')
        % Determine slice order from json
        % Load json and process string (this is clunky because matlab has no 
        % *documented* json parser and I'm hesitant to use the internal one
        % in case they break it in future updates).       
        spm12w_logger('msg',sprintf(['[DEBUG] Loading slicetiming info from ', ... 
                  'SliceTiming field at file:%s'], jpath),'level',p.loglevel)
        fid = fopen(jpath);
        raw = fread(fid,inf);
        str = char(raw');
        fclose(fid);    
        [tmp_str,~] = strsplit(str,'"SliceTiming": [');
        [tmp_str,~] = strsplit(tmp_str{2},']');
        slicetiming = str2num(tmp_str{1});
        % Some json files seems to store SliceTiming in columns (Dartmouth)
        % others seem to store SliceTiming in rows (OSU). So only transpose
        % if necessary (i.e., rows).
        [m,n] = size(slicetiming);
        if m > n
            p.sliceorder = slicetiming';
        else
            p.sliceorder = slicetiming;
        end   
        % Check if simultaneous slice acquisition by looking to see if there  
        % are duplicate slice times.
        if length(unique(p.sliceorder)) < length(p.sliceorder)
            spm12w_logger('msg',['Detected multiple identical slicetimes, ', ...
                          'assuming multi-slice acquisition'],'level',p.loglevel)
            spm12w_logger('msg',sprintf('SMS Slicetiming (json) is: %s', ...
                      mat2str(p.sliceorder)),'level',p.loglevel)
            p.refslice = p.sliceorder(p.refslice);
            spm12w_logger('msg',sprintf('SMS Reference slice time is: %1.3f', ...
                      p.refslice),'level',p.loglevel)
        else
            % Convert to sliceorder
            [~, p.sliceorder] = ismember(p.sliceorder,sort(p.sliceorder)); 
            spm12w_logger('msg',sprintf('Sliceorder (json) is: %s', ...
                      mat2str(p.sliceorder)),'level',p.loglevel)
        end
    elseif strcmp(p.sformula, 'philips')
    % Formula for interleaved sqeuence on Philips Achieva 3T
        for i = 1:round(sqrt(p.nslice))
            p.sliceorder = [p.sliceorder i:round(sqrt(p.nslice)):p.nslice];
        end
        spm12w_logger('msg',sprintf('Sliceorder (philips) is: %s', ...
                      mat2str(p.sliceorder)), 'level',p.loglevel)
    else
        % Formula for interleaved bottom-up sequence 
        p.sliceorder=[1:2:p.nslice 2:2:p.nslice];
        spm12w_logger('msg',sprintf(['Sliceorder (interleaved bottom-up) ',...
                      'is: %s'],mat2str(p.sliceorder)), 'level',p.loglevel)
    end
else
    spm12w_logger('msg',['[EXCEPTION] Runs do not match number of ' ... 
                  'slices. Aborting...'],'level',p.loglevel)
    diary off
    error('Runs do not match on number of slices...')
end

% Verify TRs and give warning if fail check 
if length(unique(tr)) ~= 1
    spm12w_logger('msg',['[WARNING] Runs do not match on TR. Make sure' ... 
                  ' this is intentional! Proceeding...'],'level',p.loglevel)
end