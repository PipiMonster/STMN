function net_inputs = rfcn_get_minibatch(conf, image_roidb)
% net_inputs = rfcn_get_minibatch(conf, image_roidb)
% --------------------------------------------------------
% D&T implementation
% Modified from MATLAB  R-FCN (https://github.com/daijifeng001/R-FCN/)
% and Faster R-CNN (https://github.com/shaoqingren/faster_rcnn)
% Copyright (c) 2017, Christoph Feichtenhofer
% Licensed under The MIT License [see LICENSE for details]
% --------------------------------------------------------   
    visualize = false;

    num_images = length(image_roidb);
    if num_images == 0
      net_inputs = NaN; return;                              
    end
    if conf.bbox_class_agnostic
        num_classes = 1;
    else
        % Infer number of classes from the number of columns in gt_overlaps
        num_classes = size(image_roidb(1).overlap, 2);
    end
    % Sample random scales to use for each image in this batch
    random_scale_inds = randi(length(conf.scales), num_images, 1);
    
    if conf.batch_size > 0
        assert(mod(conf.batch_size, num_images) == 0, ...
        sprintf('num_images %d must divide BATCH_SIZE %d', num_images, conf.batch_size));

        rois_per_image = conf.batch_size / num_images;
        fg_rois_per_image = round(rois_per_image * conf.fg_fraction);
    else
        rois_per_image = inf;
        fg_rois_per_image = inf;
    end
    if conf.use_flipped
      flip_im = rand(num_images,1) > .5;
      if isfield(conf,'sample_vid') && conf.sample_vid, flip_im = repmat(flip_im(1), size(flip_im)); end;
    else
      flip_im = zeros(num_images,1) ;
    end
    % Get the input image blob
    [im_blob, im_scales] = get_image_blob(conf, image_roidb, random_scale_inds, flip_im);
    if isnan(im_blob), net_inputs = NaN; return; end
    % build the region of interest and label blobs
    rois_blob = zeros(0, 5, 'single');
    labels_blob = zeros(0, 1, 'single');
    bbox_targets_blob = zeros(0, 4 * (num_classes+1), 'single');
    bbox_loss_blob = zeros(size(bbox_targets_blob), 'single');
    track_rois_blob = rois_blob; track_targets_blob = bbox_targets_blob; track_loss_blob = bbox_loss_blob;
    for i = 1:num_images
        [labels, ~, im_rois, bbox_targets, bbox_loss] = ...
            sample_rois(conf, image_roidb(i), fg_rois_per_image, rois_per_image);
          
        if flip_im(i)
            im_rois(:, [1, 3]) = image_roidb(i).im_size(2) + 1 - im_rois(:, [3, 1]);
            %flip horizontal regression target: targets_dx = (gt_ctr_x - ex_ctr_x) ./ (ex_widths+eps);
            bbox_targets(:, 5) = - bbox_targets(:, 5);
        end
        
        if visualize
          im = (imread(  image_roidb(i).image_path ));
          boxes_cell = {im_rois(:,:)};
          
          figure('windowstyle','docked'); 
          imd(im);
          drawBBoxes(im_rois(:,:), 'LineWidth', 1);
        end
          
        % Add to ROIs blob
        feat_rois = rfcn_map_im_rois_to_feat_rois(conf, im_rois, im_scales(i));
        batch_ind = i * ones(size(feat_rois, 1), 1);
        rois_blob_this_image = [batch_ind, feat_rois];
        rois_blob = [rois_blob; rois_blob_this_image];
        
        % Add to labels, bbox targets, and bbox loss blobs
        labels_blob = [labels_blob; labels];
        bbox_targets_blob = [bbox_targets_blob; bbox_targets];
        bbox_loss_blob = [bbox_loss_blob; bbox_loss];
        
        if isfield(image_roidb(i), 'track_targets') && ~isempty(image_roidb(i).track_targets)
          [track_targets, track_loss_weights] = get_bbox_regression_labels(conf,  image_roidb(i).track_targets, num_classes);

          if flip_im(i)
             image_roidb(i).track_rois(:, [1, 3])  = image_roidb(i).im_size(2) + 1 - image_roidb(i).track_rois(:, [3, 1]);
             track_targets(:, 5) = - track_targets(:, 5);
          end
            track_rois_blob = [track_rois_blob; [ones(size(image_roidb(i).track_rois, 1), 1), rfcn_map_im_rois_to_feat_rois(conf, image_roidb(i).track_rois, im_scales(i))]]; 
            track_targets_blob = [track_targets_blob; track_targets];
            track_loss_blob = [track_loss_blob; track_loss_weights];
        end
    end
        
    % permute data into caffe c++ memory, thus [num, channels, height, width]
    im_blob(:, :, 1:3, :) = im_blob(:, :, [3, 2, 1], :); % from rgb to brg
    if size(im_blob,3) > 3
      im_blob(:, :, 4:6, :) = im_blob(:, :, [6, 5, 4], :); % from rgb to brg
    end
    im_blob = single(permute(im_blob, [2, 1, 3, 4]));
    rois_blob = rois_blob - 1; % to c's index (start from 0)
    rois_blob = single(permute(rois_blob, [3, 4, 2, 1]));
    labels_blob = single(permute(labels_blob, [3, 4, 2, 1]));
    bbox_targets_blob = single(permute(bbox_targets_blob, [3, 4, 2, 1])); 
    bbox_loss_blob = single(permute(bbox_loss_blob, [3, 4, 2, 1]));
    
    track_rois_blob = track_rois_blob -1; 
    track_rois_blob = single(permute(track_rois_blob, [3, 4, 2, 1]));
    track_targets_blob = single(permute(track_targets_blob, [3, 4, 2, 1])); 
    track_loss_blob = single(permute(track_loss_blob, [3, 4, 2, 1]));
    
    try
    assert(~isempty(im_blob));
    assert(~isempty(rois_blob));
    assert(~isempty(labels_blob));
    assert(~isempty(bbox_targets_blob));
    assert(~isempty(bbox_loss_blob));
    catch
      fprintf('no object in image %s\n', image_roidb(1).image_path );
       net_inputs = NaN; return; 
    end
    if ~isempty(track_rois_blob)
      net_inputs = {im_blob, rois_blob, labels_blob, bbox_targets_blob, bbox_loss_blob, ...
        track_rois_blob, track_targets_blob, track_loss_blob};
    else
      net_inputs = {im_blob, rois_blob, labels_blob, bbox_targets_blob, bbox_loss_blob};
    end
   
    
end

%% Build an input blob from the images in the roidb at the specified scales.
function [im_blob, im_scales] = get_image_blob(conf, images, random_scale_inds, flip_im)
    
    num_images = length(images);
    processed_ims = cell(num_images, 1);
    im_scales = nan(num_images, 1);
    for i = 1:num_images
      try
        if ~ispc
          images(i).image_path = strrep(images(i).image_path,'\','/');
        end
        nFrames = 1;
       if isfield(conf, 'nFrames')
         nFrames = conf.nFrames;
       end
        if isfield(conf, 'input_modality') && ~strcmp(conf.input_modality, 'rgb')
          if strcmp(conf.input_modality, '2framergb') || strcmp(conf.input_modality, 'framebatch') 
            time_stride = 10;
             if isfield(conf, 'time_stride')
               time_stride = conf.time_stride;
             end
            [vid, frame, ext] = fileparts(images(i).image_path);
            nextframe = fullfile(vid, [sprintf('%06d',str2num(frame)+time_stride) ext]) ;
            frames = str2num(frame)-nFrames/2*time_stride:time_stride:str2num(frame)+nFrames/2*time_stride;
            im = {};
            for frame=frames
              nextframe = fullfile(vid, [sprintf('%06d',frame) ext]) ;
              im{end+1} = imread(nextframe); 
            end
            if strcmp(conf.input_modality, 'framebatch')            
              im = cat(4,im{:});
            else
              im = cat(3,im{:});
            end

          else
            if strcmp(images(i).imdb_name(1:12), 'ilsvrc15_vid')
              img_file_u = strrep(images(i).image_path, ['Data' filesep 'VID'], ...
                ['Data' filesep 'VID' filesep 'tvl1_flow_600' filesep 'u'] ) ; 
              img_file_v = strrep(images(i).image_path, ['Data' filesep 'VID'], ...
                ['Data' filesep 'VID' filesep 'tvl1_flow_600' filesep 'v'] ) ; 
              try
                [path_u, ~, ~] = fileparts(img_file_u);
                [path_v, frame, ext] = fileparts(img_file_v);
                frames = str2num(frame)-nFrames+1:str2num(frame)+nFrames-1;
                frames(frames <0) = 0; frames(frames > imdb.num_frames(i)) = imdb.num_frames(i);
                im_u = []; im_v = [];
                for frame=frames
                  img_file_u = fullfile(path_u, [sprintf('%06d',frame), ext]) ;
                  img_file_v = fullfile(path_v, [sprintf('%06d',frame), ext]) ;
                  im_u{end+1} = imread(img_file_u); im_v{end+1} = imread(img_file_v); 
                end
                im_u = cat(3,im_u{:});im_v = cat(3,im_v{:});
              end
            else
              im_u = 128*ones(images(i).im_size); im_v = 128*ones(images(i).im_size);
            end
            sz = size(im_u);  
          end
          switch conf.input_modality
            case 'flow'
              flow = single(cat(3,im_u,im_v)) - 128;
              flow = bsxfun(@minus,flow, median(median(flow,1),2)) ; 
              mag_flow = sqrt(sum(flow.^2,3)) - 128; 
              im = (cat(3,flow,mag_flow));
              im = imresize( im, images(i).im_size);
            case 'grayflow'
              imrgb = imread(images(i).image_path); sz = size(imrgb);
              imgray = rgb2gray(imrgb);
              flow = single(cat(3,im_u,im_v)) ;
              im = cat(3,imresize( flow, sz(1:2)),imgray);
            case 'rgbflow'
            if isfield(conf, 'subflow_mean') && ~conf.subflow_mean
              flow = single(cat(3,im_u,im_v));
            else
              flow = single(cat(3,im_u,im_v)) - 128;
            end
            imrgb = single(imread(images(i).image_path));
     
            if size(imrgb,3) < 3
              imrgb = imrgb(:,:,[1 1 1]);
            end
            sz = size(imrgb);
            im = cat(3,imrgb,imresize( flow, sz(1:2)));
          end
        else
            im = imread(images(i).image_path);
        end
      catch
        fprintf('could not read %s\n', images(i).image_path);
        im_blob = NaN;
        return;
      end
        target_size = conf.scales(random_scale_inds(i));
        
        if flip_im(i)
            im = fliplr(im);
        end
        [im, im_scale] = prep_im_for_blob(im, conf.image_means, target_size, conf.max_size);
        if isfield(conf,'image_std')
          im = bsxfun(@rdivide, im, conf.image_std);
        end
        im_scales(i) = im_scale;
        processed_ims{i} = im; 
    end
    
    im_blob = im_list_to_blob(processed_ims);
end

%% Generate a random sample of ROIs comprising foreground and background examples.
function [labels, overlaps, rois, bbox_targets, bbox_loss_weights] = sample_rois(conf, image_roidb, fg_rois_per_image, rois_per_image)

    [overlaps, labels] = max(image_roidb(1).overlap, [], 2);
    rois = image_roidb(1).boxes;
    
    % Select foreground ROIs as those with >= FG_THRESH overlap
    fg_inds = find(overlaps >= conf.fg_thresh);
    % Guard against the case when an image has fewer than fg_rois_per_image
    % foreground ROIs
    fg_rois_per_this_image = min(fg_rois_per_image, length(fg_inds));
    % Sample foreground regions without replacement
    if ~isempty(fg_inds)
       fg_inds = fg_inds(randperm(length(fg_inds), fg_rois_per_this_image));
    end
    
    % Select background ROIs as those within [BG_THRESH_LO, BG_THRESH_HI)
    bg_inds = find(overlaps < conf.bg_thresh_hi & overlaps >= conf.bg_thresh_lo);
    % Compute number of background ROIs to take from this image (guarding
    % against there being fewer than desired)
    bg_rois_per_this_image = rois_per_image - fg_rois_per_this_image;
    bg_rois_per_this_image = min(bg_rois_per_this_image, length(bg_inds));
    % Sample foreground regions without replacement
    if ~isempty(bg_inds)
       bg_inds = bg_inds(randperm(length(bg_inds), bg_rois_per_this_image));
    end
    % The indices that we're selecting (both fg and bg)
    keep_inds = [fg_inds; bg_inds];
    % Select sampled values from various arrays
    labels = labels(keep_inds);
    % Clamp labels for the background ROIs to 0
    labels((fg_rois_per_this_image+1):end) = 0;
    overlaps = overlaps(keep_inds);
    rois = rois(keep_inds, :);
    
    if conf.bbox_class_agnostic
        assert(all((labels>0) == image_roidb.bbox_targets(keep_inds, 1)));
    else
        assert(all(labels == image_roidb.bbox_targets(keep_inds, 1)));
    end
    
    % Infer number of classes from the number of columns in gt_overlaps
    num_classes = size(image_roidb(1).overlap, 2);
    
    [bbox_targets, bbox_loss_weights] = get_bbox_regression_labels(conf, ...
        image_roidb.bbox_targets(keep_inds, :), num_classes);
    
end

function [bbox_targets, bbox_loss_weights] = get_bbox_regression_labels(conf, bbox_target_data, num_classes)
%% Bounding-box regression targets are stored in a compact form in the roidb.
 % This function expands those targets into the 4-of-4*(num_classes+1) representation used
 % by the network (i.e. only one class has non-zero targets).
 % The loss weights are similarly expanded.
% Return (N, (num_classes+1) * 4, 1, 1) blob of regression targets
% Return (N, (num_classes+1 * 4, 1, 1) blob of loss weights
    if conf.bbox_class_agnostic
        num_classes = 1;
    end
    
    clss = bbox_target_data(:, 1);
    bbox_targets = zeros(length(clss), 4 * (num_classes+1), 'single');
    bbox_loss_weights = zeros(size(bbox_targets), 'single');
    inds = find(clss > 0);
    for i = 1:length(inds)
       ind = inds(i);
       cls = clss(ind);
       targets_inds = (1+cls*4):((cls+1)*4);
       bbox_targets(ind, targets_inds) = bbox_target_data(ind, 2:end);
       bbox_loss_weights(ind, targets_inds) = 1;  
    end
end



