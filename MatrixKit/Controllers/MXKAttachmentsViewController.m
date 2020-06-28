/*
 Copyright 2015 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXKAttachmentsViewController.h"
#import <Webkit/WebKit.h>
#import "MXKAlert.h"

#import "MXKMediaCollectionViewCell.h"

#import "MXKMediaManager.h"

#import "MXKPieChartView.h"

#import "MXKConstants.h"

#import "NSBundle+MatrixKit.h"

#import "MXKEventFormatter.h"

#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
@interface MXKAttachmentsViewController ()
{
    /**
     Current alert (if any).
     */
    MXKAlert *currentAlert;

    /**
     Navigation bar handling
     */
    NSTimer *navigationBarDisplayTimer;
    
    /**
     SplitViewController handling
     */
    BOOL shouldRestoreBottomBar;
    UISplitViewControllerDisplayMode savedSplitViewControllerDisplayMode;
    
    /**
     Audio session handling
     */
    NSString *savedAVAudioSessionCategory;
    
    /**
     The attachments array (MXAttachment instances).
     */
    NSMutableArray *attachments;
    
    /**
     The index of the current visible collection item
     */
    NSInteger currentVisibleItemIndex;
    
    /**
     The document interaction Controller used to share attachment
     */
    UIDocumentInteractionController *documentInteractionController;
    MXKAttachment *currentSharedAttachment;
    
    /**
     Tells whether back pagination is in progress.
     */
    BOOL isBackPaginationInProgress;
}

@end

@implementation MXKAttachmentsViewController
@synthesize attachments;

#pragma mark - Class methods

+ (UINib *)nib
{
    return [UINib nibWithNibName:NSStringFromClass([MXKAttachmentsViewController class])
                          bundle:[NSBundle bundleForClass:[MXKAttachmentsViewController class]]];
}

+ (instancetype)attachmentsViewController
{
    return [[[self class] alloc] initWithNibName:NSStringFromClass([MXKAttachmentsViewController class])
                                          bundle:[NSBundle bundleForClass:[MXKAttachmentsViewController class]]];
}

#pragma mark -

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Check whether the view controller has been pushed via storyboard
    if (!_attachmentsCollection)
    {
        // Instantiate view controller objects
        [[[self class] nib] instantiateWithOwner:self options:nil];
    }
    
    // Register collection view cell class
    [self.attachmentsCollection registerClass:MXKMediaCollectionViewCell.class forCellWithReuseIdentifier:[MXKMediaCollectionViewCell defaultReuseIdentifier]];
    
    // Hide collection to hide first scrolling into the attachments.
    _attachmentsCollection.hidden = YES;
    
    // Display collection cell in full screen
    self.automaticallyAdjustsScrollViewInsets = NO;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    savedAVAudioSessionCategory = [[AVAudioSession sharedInstance] category];
    
    // Hide navigation bar by default.
    // For unknown reason, we have to wait for 'viewDidAppear' in iOS < 9.0, the bar is then visible a few seconds.
    // We decided to hide it here on iOS 9 and later. Patch: we check a method available on iOS 9 and later.
    if ([self respondsToSelector:@selector(loadViewIfNeeded)])
    {
        [self hideNavigationBar];
    }
    
    // Hide status bar
    [UIApplication sharedApplication].statusBarHidden = NO;
    
    // Handle here the case of splitviewcontroller use on iOS 8 and later.
    if (self.splitViewController && [self.splitViewController respondsToSelector:@selector(displayMode)])
    {
        if (self.hidesBottomBarWhenPushed)
        {
            // This screen should be displayed without tabbar, but hidesBottomBarWhenPushed flag has no effect in case of splitviewcontroller use.
            // Trick: on iOS 8 and later the tabbar is hidden manually
            shouldRestoreBottomBar = YES;
            self.tabBarController.tabBar.hidden = YES;
        }
        
        // Hide the primary view controller to allow full screen display
        savedSplitViewControllerDisplayMode = [self.splitViewController displayMode];
        self.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModePrimaryHidden;
        [self.splitViewController.view layoutIfNeeded];
    }
    
    [_attachmentsCollection reloadData];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    if (self.navigationController.navigationBarHidden == NO)
    {
        [self hideNavigationBar];
    }
    
    // Adjust content offset and make visible the attachmnet collections
    [self refreshAttachmentCollectionContentOffset];
    _attachmentsCollection.hidden = NO;
}

- (void)viewWillDisappear:(BOOL)animated
{
    if (currentAlert)
    {
        [currentAlert dismiss:NO];
        currentAlert = nil;
    }
    
    // Restore audio category
    if (savedAVAudioSessionCategory)
    {
        [[AVAudioSession sharedInstance] setCategory:savedAVAudioSessionCategory error:nil];
        savedAVAudioSessionCategory = nil;
    }
    
    [navigationBarDisplayTimer invalidate];
    navigationBarDisplayTimer = nil;
    self.navigationController.navigationBarHidden = NO;
    
    // Restore status bar
    [UIApplication sharedApplication].statusBarHidden = NO;
    
    if (shouldRestoreBottomBar)
    {
        self.tabBarController.tabBar.hidden = NO;
    }
    
    if (self.splitViewController && [self.splitViewController respondsToSelector:@selector(displayMode)])
    {
        self.splitViewController.preferredDisplayMode = savedSplitViewControllerDisplayMode;
        [self.splitViewController.view layoutIfNeeded];
    }
    
    [super viewWillDisappear:animated];
}

- (void)dealloc
{
    [self destroy];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    // Store index of the current displayed attachment, to restore it after refreshing
    [self refreshCurrentVisibleItemIndex];
    
    // Show temporarily the navigation bar (required in case of splitviewcontroller use)
    self.navigationController.navigationBarHidden = NO;
    [navigationBarDisplayTimer invalidate];
    navigationBarDisplayTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(hideNavigationBar) userInfo:self repeats:NO];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(coordinator.transitionDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Cell width will be updated, force collection layout refresh to take into account the changes
        [_attachmentsCollection.collectionViewLayout invalidateLayout];
        
        // Refresh the current attachment display
        [self refreshAttachmentCollectionContentOffset];
        
    });
}

// The 2 following methods are deprecated since iOS 8
- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    
    // Store index of the current displayed attachment, to restore it after refreshing
    [self refreshCurrentVisibleItemIndex];
    
    // Show temporarily the navigation bar (required in case of splitviewcontroller use)
    self.navigationController.navigationBarHidden = NO;
    [navigationBarDisplayTimer invalidate];
    navigationBarDisplayTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(hideNavigationBar) userInfo:self repeats:NO];
}
- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation
{
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    
    // Cell width will be updated, force collection refresh to take into account changes.
    dispatch_async(dispatch_get_main_queue(), ^{
        
        [_attachmentsCollection.collectionViewLayout invalidateLayout];
        
        // Refresh the current attachment display
        [self refreshAttachmentCollectionContentOffset];
        
    });
}

#pragma mark - Override MXKViewController

- (void)destroy
{
    if (documentInteractionController)
    {
        [documentInteractionController dismissPreviewAnimated:NO];
        [documentInteractionController dismissMenuAnimated:NO];
        documentInteractionController = nil;
    }
    
    if (currentSharedAttachment)
    {
        [currentSharedAttachment onShareEnded];
        currentSharedAttachment = nil;
    }
    
    [super destroy];
}

#pragma mark - Public API

- (void)displayAttachments:(NSArray*)attachmentArray focusOn:(NSString*)eventId
{
    NSString *currentAttachmentEventId = eventId;
    NSString *currentAttachmentOriginalFileName = nil;
    
    if (currentAttachmentEventId.length == 0 && attachments)
    {
        if (isBackPaginationInProgress && currentVisibleItemIndex == 0)
        {
            // Here the spinner were displayed, we update the viewer by displaying the first added attachment
            // (the one just added before the first item of the current attachments array).
            if (attachments.count)
            {
                // Retrieve the event id of the first item in the current attachments array
                MXKAttachment *attachment = attachments[0];
                NSString *firstAttachmentEventId = attachment.event.eventId;
                NSString *firstAttachmentOriginalFileName = nil;
                
                // The original file name is used when the attachment is a local echo.
                // Indeed its event id may be replaced by the actual one in the new attachments array.
                if ([firstAttachmentEventId hasPrefix:kMXKEventFormatterLocalEventIdPrefix])
                {
                    firstAttachmentOriginalFileName = attachment.originalFileName;
                }
                
                // Look for the attachment added before this attachment in new array.
                for (attachment in attachmentArray)
                {
                    if (firstAttachmentOriginalFileName && [attachment.originalFileName isEqualToString:firstAttachmentOriginalFileName])
                    {
                        break;
                    }
                    else if ([attachment.event.eventId isEqualToString:firstAttachmentEventId])
                    {
                        break;
                    }
                    currentAttachmentEventId = attachment.event.eventId;
                }
            }
        }
        else if (currentVisibleItemIndex != NSNotFound)
        {
            // Compute the attachment index
            NSUInteger currentAttachmentIndex = (isBackPaginationInProgress ? currentVisibleItemIndex - 1 : currentVisibleItemIndex);
            
            if (currentAttachmentIndex < attachments.count)
            {
                MXKAttachment *attachment = attachments[currentAttachmentIndex];
                currentAttachmentEventId = attachment.event.eventId;
                
                // The original file name is used when the attachment is a local echo.
                // Indeed its event id may be replaced by the actual one in the new attachments array.
                if ([currentAttachmentEventId hasPrefix:kMXKEventFormatterLocalEventIdPrefix])
                {
                    currentAttachmentOriginalFileName = attachment.originalFileName;
                }
            }
        }
    }
    
    // Stop back pagination (Do not call here 'stopBackPaginationActivity' because a full collection reload is planned at the end).
    isBackPaginationInProgress = NO;
    
    // Set/reset the attachments array
    attachments = [NSMutableArray arrayWithArray:attachmentArray];
    
    // Update the index of the current displayed attachment by looking for the
    // current event id (or the current original file name, if any) in the new attachments array.
    currentVisibleItemIndex = 0;
    if (currentAttachmentEventId)
    {
        for (NSUInteger index = 0; index < attachments.count; index++)
        {
            MXKAttachment *attachment = attachments[index];
            
            // Check first the original filename if any.
            if (currentAttachmentOriginalFileName && [attachment.originalFileName isEqualToString:currentAttachmentOriginalFileName])
            {
                currentVisibleItemIndex = index;
                break;
            }
            // Check the event id then
            else if ([attachment.event.eventId isEqualToString:currentAttachmentEventId])
            {
                currentVisibleItemIndex = index;
                break;
            }
        }
    }
    
    // Refresh
    [_attachmentsCollection reloadData];
    
    // Adjust content offset
    [self refreshAttachmentCollectionContentOffset];
}

- (void)setComplete:(BOOL)complete
{
    _complete = complete;
    
    if (complete)
    {
        [self stopBackPaginationActivity];
    }
}

#pragma mark - Privates

- (IBAction)hideNavigationBar
{
    self.navigationController.navigationBarHidden = NO;
    
    [navigationBarDisplayTimer invalidate];
    navigationBarDisplayTimer = nil;
}

- (void)refreshCurrentVisibleItemIndex
{
    // Check whether the collection is actually rendered
    if (_attachmentsCollection.contentSize.width)
    {
        currentVisibleItemIndex = _attachmentsCollection.contentOffset.x / [[UIScreen mainScreen] bounds].size.width;
    }
    else
    {
        currentVisibleItemIndex = NSNotFound;
    }
}

- (void)refreshAttachmentCollectionContentOffset
{
    if (currentVisibleItemIndex != NSNotFound && _attachmentsCollection)
    {
        // Set the content offset to display the current attachment
        CGPoint contentOffset = _attachmentsCollection.contentOffset;
        contentOffset.x = currentVisibleItemIndex * [[UIScreen mainScreen] bounds].size.width;
        _attachmentsCollection.contentOffset = contentOffset;
    }
}

- (void)refreshCurrentVisibleCell
{
    // In case of attached image, load here the high res image.
    
    [self refreshCurrentVisibleItemIndex];
    
    if (currentVisibleItemIndex != NSNotFound)
    {
        NSInteger item = currentVisibleItemIndex;
        if (isBackPaginationInProgress)
        {
            if (item == 0)
            {
                return;
            }
            
            item --;
        }
        
        if (item < attachments.count)
        {
            MXKAttachment *attachment = attachments[item];
            NSString *attachmentURL = attachment.actualURL;
            NSString *mimeType = attachment.contentInfo[@"mimetype"];
            
            // Check attachment type
            if (attachment.type == MXKAttachmentTypeImage && attachmentURL.length && ![mimeType isEqualToString:@"image/gif"])
            {
                // Retrieve the related cell
                UICollectionViewCell *cell = [_attachmentsCollection cellForItemAtIndexPath:[NSIndexPath indexPathForItem:currentVisibleItemIndex inSection:0]];
                
                if ([cell isKindOfClass:[MXKMediaCollectionViewCell class]])
                {
                    MXKMediaCollectionViewCell *mediaCollectionViewCell = (MXKMediaCollectionViewCell*)cell;
                    
                    // Load high res image
                    mediaCollectionViewCell.mxkImageView.stretchable = YES;
                    mediaCollectionViewCell.mxkImageView.enableInMemoryCache = NO;
                    
                    // Use the current image as preview
                    UIImage *preview = mediaCollectionViewCell.mxkImageView.image;
                    if (!preview)
                    {
                        // Check whether the thumbnail has just been downloaded and cached
                        NSString *previewCacheFilePath = [MXKMediaManager cachePathForMediaWithURL:attachment.thumbnailURL
                                                                                           andType:mimeType
                                                                                          inFolder:attachment.event.roomId];
                        preview = [MXKMediaManager loadPictureFromFilePath:previewCacheFilePath];
                    }
                    
                    [mediaCollectionViewCell.mxkImageView setImageURL:attachmentURL withType:mimeType andImageOrientation:UIImageOrientationUp previewImage:preview];
                }
            }
        }
    }
}

- (void)stopBackPaginationActivity
{
    if (isBackPaginationInProgress)
    {
        isBackPaginationInProgress = NO;
        
        [self.attachmentsCollection deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
    }
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    if (isBackPaginationInProgress)
    {
        return (attachments.count + 1);
    }
    
    return attachments.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    MXKMediaCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:[MXKMediaCollectionViewCell defaultReuseIdentifier]
                                                                                 forIndexPath:indexPath];
    
    NSInteger item = indexPath.item;
    
    if (isBackPaginationInProgress)
    {
        if (item == 0)
        {
            cell.mxkImageView.hidden = YES;
            cell.customView.hidden = NO;
            
            // Add back pagination spinner
            UIActivityIndicatorView* spinner  = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
            spinner.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin);
            spinner.hidesWhenStopped = NO;
            spinner.backgroundColor = [UIColor clearColor];
            [spinner startAnimating];
            
            spinner.center = cell.customView.center;
            [cell.customView addSubview:spinner];
            
            return cell;
        }
        
        item --;
    }
    
    if (item < attachments.count)
    {
        MXKAttachment *attachment = attachments[item];
        NSString *attachmentURL = attachment.actualURL;
        NSString *mimeType = attachment.contentInfo[@"mimetype"];
        
        // Use the cached thumbnail (if any) as preview
        NSString *previewCacheFilePath = [MXKMediaManager cachePathForMediaWithURL:attachment.thumbnailURL
                                                                           andType:mimeType
                                                                          inFolder:attachment.event.roomId];
        UIImage* preview = [MXKMediaManager loadPictureFromFilePath:previewCacheFilePath];
        
        // Check attachment type
        if (attachment.type == MXKAttachmentTypeImage && attachmentURL.length)
        {
            if ([mimeType isEqualToString:@"image/gif"])
            {
                cell.mxkImageView.hidden = YES;
                cell.customView.hidden = NO;
                
                // Animated gif is displayed in webview
                CGFloat minSize = (cell.frame.size.width < cell.frame.size.height) ? cell.frame.size.width : cell.frame.size.height;
                CGFloat width, height;
                if (attachment.contentInfo[@"w"] && attachment.contentInfo[@"h"])
                {
                    width = [attachment.contentInfo[@"w"] integerValue];
                    height = [attachment.contentInfo[@"h"] integerValue];
                    if (width > minSize || height > minSize)
                    {
                        if (width > height)
                        {
                            height = (height * minSize) / width;
                            height = floorf(height / 2) * 2;
                            width = minSize;
                        }
                        else
                        {
                            width = (width * minSize) / height;
                            width = floorf(width / 2) * 2;
                            height = minSize;
                        }
                    }
                    else
                    {
                        width = minSize;
                        height = minSize;
                    }
                }
                else
                {
                    width = minSize;
                    height = minSize;
                }
                
                WKWebView *animatedGifViewer = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
                animatedGifViewer.center = cell.customView.center;
                animatedGifViewer.opaque = NO;
                animatedGifViewer.backgroundColor = cell.customView.backgroundColor;
                animatedGifViewer.contentMode = UIViewContentModeScaleAspectFit;
                //animatedGifViewer.scalesPageToFit = YES;
                animatedGifViewer.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin);
                animatedGifViewer.userInteractionEnabled = NO;
                [cell.customView addSubview:animatedGifViewer];
                
                UIImageView *previewImage = [[UIImageView alloc] initWithFrame:animatedGifViewer.frame];
                previewImage.contentMode = animatedGifViewer.contentMode;
                previewImage.autoresizingMask = animatedGifViewer.autoresizingMask;
                previewImage.image = preview;
                previewImage.center = cell.customView.center;
                [cell.customView addSubview:previewImage];
                
                MXKPieChartView *pieChartView = [[MXKPieChartView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
                pieChartView.progress = 0;
                pieChartView.progressColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:0.25];
                pieChartView.unprogressColor = [UIColor clearColor];
                pieChartView.autoresizingMask = animatedGifViewer.autoresizingMask;
                pieChartView.center = cell.customView.center;
                [cell.customView addSubview:pieChartView];
                
                // Add download progress observer
                cell.notificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kMXKMediaDownloadProgressNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
                    
                    if ([notif.object isEqualToString:attachmentURL])
                    {
                        if (notif.userInfo)
                        {
                            NSNumber* progressNumber = [notif.userInfo valueForKey:kMXKMediaLoaderProgressValueKey];
                            
                            if (progressNumber)
                            {
                                pieChartView.progress = progressNumber.floatValue;
                            }
                        }
                    }
                    
                }];
                
                [attachment prepare:^{
                    
                    if (cell.notificationObserver)
                    {
                        [[NSNotificationCenter defaultCenter] removeObserver:cell.notificationObserver];
                        cell.notificationObserver = nil;
                    }
                    
                    if (animatedGifViewer.superview)
                    {
                        [animatedGifViewer loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:attachment.cacheFilePath]]];
                        
                        [pieChartView removeFromSuperview];
                        [previewImage removeFromSuperview];
                    }
                    
                } failure:^(NSError *error) {
                    
                    if (cell.notificationObserver)
                    {
                        [[NSNotificationCenter defaultCenter] removeObserver:cell.notificationObserver];
                        cell.notificationObserver = nil;
                    }
                    
                    NSLog(@"[MXKAttachmentsVC] gif download failed: %@", error);
                    // Notify MatrixKit user
                    [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error];
                    
                }];
            }
            else if (indexPath.item == currentVisibleItemIndex)
            {
                // Load high res image
                cell.mxkImageView.mediaFolder = attachment.event.roomId;
                cell.mxkImageView.stretchable = YES;
                cell.mxkImageView.enableInMemoryCache = NO;
                
                [cell.mxkImageView setImageURL:attachmentURL withType:mimeType andImageOrientation:UIImageOrientationUp previewImage:preview];
            }
            else
            {
                // Use the thumbnail here - Full res images should only be downloaded explicitly when requested (see [self refreshCurrentVisibleItemIndex])
                cell.mxkImageView.mediaFolder = attachment.event.roomId;
                cell.mxkImageView.stretchable = YES;
                cell.mxkImageView.enableInMemoryCache = YES;
                
                [cell.mxkImageView setImageURL:attachment.thumbnailURL withType:mimeType andImageOrientation:UIImageOrientationUp previewImage:preview];
            }
        }
        else if (attachment.type == MXKAttachmentTypeVideo && attachmentURL.length)
        {
            cell.mxkImageView.mediaFolder = attachment.event.roomId;
            cell.mxkImageView.stretchable = NO;
            cell.mxkImageView.enableInMemoryCache = YES;
            // Display video thumbnail, the video is played only when user selects this cell
            [cell.mxkImageView setImageURL:attachment.thumbnailURL withType:mimeType andImageOrientation:attachment.thumbnailOrientation previewImage:nil];
            
            cell.centerIcon.image = [NSBundle mxk_imageFromMXKAssetsBundleWithName:@"play"];
            cell.centerIcon.hidden = NO;
        }
        
        // Add gesture recognizers on collection cell to handle tap and long press on collection cell.
        // Note: tap gesture recognizer is required here because mxkImageView enables user interaction to allow image stretching.
        // [collectionView:didSelectItemAtIndexPath] is not triggered when mxkImageView is displayed.
        UITapGestureRecognizer *cellTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onCollectionViewCellTap:)];
        [cellTapGesture setNumberOfTouchesRequired:1];
        [cellTapGesture setNumberOfTapsRequired:1];
        cell.tag = item;
        [cell addGestureRecognizer:cellTapGesture];
        
        UILongPressGestureRecognizer *cellLongPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onCollectionViewCellLongPress:)];
        [cell addGestureRecognizer:cellLongPressGesture];
    }
    
    return cell;
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    NSInteger item = indexPath.item;

    BOOL navigationBarDisplayHandled = NO;
    
    if (isBackPaginationInProgress)
    {
        if (item == 0)
        {
            return;
        }
        
        item --;
    }
    
    // Check whether the selected attachment is a video
    if (item < attachments.count)
    {
        MXKAttachment *attachment = attachments[item];
        NSString *attachmentURL = attachment.actualURL;
        
        if (attachment.type == MXKAttachmentTypeVideo && attachmentURL.length)
        {
            MXKMediaCollectionViewCell *selectedCell = (MXKMediaCollectionViewCell*)[collectionView cellForItemAtIndexPath:indexPath];
            
            // Add movie player if none
            if (selectedCell.moviePlayer == nil)
            {
                [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
                
                selectedCell.moviePlayer = [[AVPlayerViewController alloc] init];
                if (selectedCell.moviePlayer != nil)
                {
                    // Switch in custom view
                    selectedCell.mxkImageView.hidden = YES;
                    selectedCell.customView.hidden = NO;
                    
                    // Report the video preview
                    UIImageView *previewImage = [[UIImageView alloc] initWithFrame:selectedCell.customView.frame];
                    previewImage.contentMode = UIViewContentModeScaleAspectFit;
                    previewImage.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin);
                    previewImage.image = selectedCell.mxkImageView.image;
                    previewImage.center = selectedCell.customView.center;
                    [selectedCell.customView addSubview:previewImage];
                    
                    //selectedCell.moviePlayer.videoGravity = AVLayerVideoGravityResizeAspect;
                    selectedCell.moviePlayer.view.frame = selectedCell.customView.frame;
                    selectedCell.moviePlayer.view.center = selectedCell.customView.center;
                    selectedCell.moviePlayer.view.hidden = YES;
                    [selectedCell.customView addSubview:selectedCell.moviePlayer.view];

                    // Force the video to stay in fullscreen
                    NSLayoutConstraint* topConstraint = [NSLayoutConstraint constraintWithItem:selectedCell.moviePlayer.view
                                                                                     attribute:NSLayoutAttributeTop
                                                                                     relatedBy:NSLayoutRelationEqual
                                                                                        toItem:selectedCell.customView
                                                                                     attribute:NSLayoutAttributeTop
                                                                                    multiplier:1.0f
                                                                                      constant:0.0f];

                    NSLayoutConstraint *trailingConstraint = [NSLayoutConstraint constraintWithItem:selectedCell.moviePlayer.view
                                                                                          attribute:NSLayoutAttributeLeading
                                                                                          relatedBy:0
                                                                                             toItem:selectedCell.customView
                                                                                          attribute:NSLayoutAttributeLeading
                                                                                         multiplier:1.0
                                                                                           constant:0];

                    NSLayoutConstraint *bottomConstraint = [NSLayoutConstraint constraintWithItem:selectedCell.moviePlayer.view
                                                                                        attribute:NSLayoutAttributeBottom
                                                                                        relatedBy:0
                                                                                           toItem:selectedCell.customView
                                                                                        attribute:NSLayoutAttributeBottom
                                                                                       multiplier:1
                                                                                         constant:0];

                    NSLayoutConstraint *tailingConstraint = [NSLayoutConstraint constraintWithItem:selectedCell.moviePlayer.view
                                                                                         attribute:NSLayoutAttributeTrailing
                                                                                         relatedBy:0
                                                                                            toItem:selectedCell.customView
                                                                                         attribute:NSLayoutAttributeTrailing
                                                                                        multiplier:1.0
                                                                                          constant:0];
                    
                    selectedCell.moviePlayer.view.translatesAutoresizingMaskIntoConstraints = NO;

                    if ([NSLayoutConstraint respondsToSelector:@selector(activateConstraints:)])
                    {
                        [NSLayoutConstraint activateConstraints:@[topConstraint, trailingConstraint, bottomConstraint, tailingConstraint]];
                    }
                    else
                    {
                        // iOS < 8 support
                        [self.view addConstraint:topConstraint];
                        [self.view addConstraint:trailingConstraint];
                        [self.view addConstraint:bottomConstraint];
                        [self.view addConstraint:tailingConstraint];
                    }

                    [[NSNotificationCenter defaultCenter] addObserver:self
                                                             selector:@selector(moviePlayerPlaybackDidFinishWithErrorNotification:)
                                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                               object:nil];
                }
            }
            
            if (selectedCell.moviePlayer)
            {
                if (selectedCell.moviePlayer.player.status == AVPlayerStatusReadyToPlay)
                {
                    // Show or hide the navigation bar

                    // The video controls bar display is automatically managed by MPMoviePlayerController.
                    // We have no control on it and no notifications about its displays changes.
                    // The following code synchronizes the display of the navigation bar with the
                    // MPMoviePlayerController controls bar.

                    // Check the MPMoviePlayerController controls bar display status by an hacky way
                    BOOL controlsVisible = NO;
                    for(id views in [[selectedCell.moviePlayer view] subviews])
                    {
                        for(id subViews in [views subviews])
                        {
                            for (id controlView in [subViews subviews])
                            {
                                if ([controlView isKindOfClass:[UIView class]] && ((UIView*)controlView).tag == 1004)
                                {
                                    controlsVisible = ([controlView alpha] <= 0.0) ? NO : YES;
                                }
                            }
                        }
                    }

                    // Apply the same display to the navigation bar
                    self.navigationController.navigationBarHidden = NO;

                    navigationBarDisplayHandled = YES;
                    if (!self.navigationController.navigationBarHidden)
                    {
                        // Automaticaly hide the nav bar after 5s. This is the same timer value that
                        // MPMoviePlayerController uses for its controls bar
                        [navigationBarDisplayTimer invalidate];
                        navigationBarDisplayTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(hideNavigationBar) userInfo:self repeats:NO];
                    }
                }
                else
                {
                    // check if the file is a local one
                    // could happen because a media upload has failed
                    if ([[NSFileManager defaultManager] fileExistsAtPath:attachmentURL])
                    {
                        selectedCell.moviePlayer.view.hidden = NO;
                        selectedCell.centerIcon.hidden = YES;
                        selectedCell.moviePlayer.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:attachmentURL]];;
                        [selectedCell.moviePlayer.player play];
                        
                        // Do not animate the navigation bar on video playback
                        return;
                    }
                    else if (selectedCell.notificationObserver == nil)
                    {
                        MXKPieChartView *pieChartView = [[MXKPieChartView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
                        pieChartView.progress = 0;
                        pieChartView.progressColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:0.25];
                        pieChartView.unprogressColor = [UIColor clearColor];
                        pieChartView.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin);
                        pieChartView.center = selectedCell.customView.center;
                        [selectedCell.customView addSubview:pieChartView];
                        
                        // Add download progress observer
                        selectedCell.notificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kMXKMediaDownloadProgressNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
                            
                            if ([notif.object isEqualToString:attachmentURL])
                            {
                                if (notif.userInfo)
                                {
                                    NSNumber* progressNumber = [notif.userInfo valueForKey:kMXKMediaLoaderProgressValueKey];
                                    
                                    if (progressNumber)
                                    {
                                        pieChartView.progress = progressNumber.floatValue;
                                    }
                                }
                            }
                            
                        }];
                        
                        [attachment prepare:^{
                            
                            if (selectedCell.notificationObserver)
                            {
                                [[NSNotificationCenter defaultCenter] removeObserver:selectedCell.notificationObserver];
                                selectedCell.notificationObserver = nil;
                            }
                            
                            if (selectedCell.moviePlayer.view.superview)
                            {
                                selectedCell.moviePlayer.view.hidden = NO;
                                selectedCell.centerIcon.hidden = YES;
                                
                                selectedCell.moviePlayer.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:attachment.cacheFilePath]];;
                                [selectedCell.moviePlayer.player play];
                                
                                [pieChartView removeFromSuperview];
                                
                                [self hideNavigationBar];
                            }
                            
                        } failure:^(NSError *error) {
                            
                            if (selectedCell.notificationObserver)
                            {
                                [[NSNotificationCenter defaultCenter] removeObserver:selectedCell.notificationObserver];
                                selectedCell.notificationObserver = nil;
                            }
                            
                            NSLog(@"[MXKAttachmentsVC] video download failed: %@", error);

                            // Display the navigation bar so that the user can leave this screen
                            self.navigationController.navigationBarHidden = NO;

                            // Notify MatrixKit user
                            [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error];
                            
                        }];
                        
                        // Do not animate the navigation bar on video playback preparing
                        return;
                    }
                }
            }
        }
    }
    
    // Animate navigation bar if it is has not been handled
    if (!navigationBarDisplayHandled)
    {
        if (self.navigationController.navigationBarHidden)
        {
            self.navigationController.navigationBarHidden = NO;
            [navigationBarDisplayTimer invalidate];
            navigationBarDisplayTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(hideNavigationBar) userInfo:self repeats:NO];
        }
        else
        {
            [self hideNavigationBar];
        }
    }
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath
{
    // Restore the cell in reusable state
    if ([cell isKindOfClass:[MXKMediaCollectionViewCell class]])
    {
        MXKMediaCollectionViewCell *mediaCollectionViewCell = (MXKMediaCollectionViewCell*)cell;
        
        mediaCollectionViewCell.mxkImageView.hidden = NO;
        mediaCollectionViewCell.customView.hidden = YES;
        
        // Cancel potential image download
        mediaCollectionViewCell.mxkImageView.enableInMemoryCache = NO;
        [mediaCollectionViewCell.mxkImageView setImageURL:nil withType:nil andImageOrientation:UIImageOrientationUp previewImage:nil];
        // TODO; we should here reset mxkImageView.stretchable flag
        // But we observed wrong behavior in case of reused cell: The stretching mechanism was disabled for unknown reason.
        // To reproduce: stretch the current image I1 with the max zoom scale, then scroll to the previous one I0, scroll back to I1: the stretching is disabled: NOK
        // Investigation is required before uncommenting the following line
//        mediaCollectionViewCell.mxkImageView.stretchable = NO;
        
        // Hide video play icon
        mediaCollectionViewCell.centerIcon.hidden = YES;
        
        // Remove potential media download observer
        if (mediaCollectionViewCell.notificationObserver)
        {
            [[NSNotificationCenter defaultCenter] removeObserver:mediaCollectionViewCell.notificationObserver];
            mediaCollectionViewCell.notificationObserver = nil;
        }
        
        // Stop potential attached player
        if (mediaCollectionViewCell.moviePlayer)
        {
            [mediaCollectionViewCell.moviePlayer.player pause];
            mediaCollectionViewCell.moviePlayer.player = nil;
        }
        // Remove added view in custon view
        NSArray *subViews = mediaCollectionViewCell.customView.subviews;
        for (UIView *view in subViews)
        {
            [view removeFromSuperview];
        }
    }
    
    // Remove all gesture recognizers
    while (cell.gestureRecognizers.count)
    {
        [cell removeGestureRecognizer:cell.gestureRecognizers[0]];
    }
    cell.tag = -1;
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset
{
    // Detect horizontal bounce at the beginning of the collection to trigger pagination
    if (scrollView == self.attachmentsCollection && !isBackPaginationInProgress && !self.complete && self.delegate)
    {
        if (scrollView.contentOffset.x < -30)
        {
            isBackPaginationInProgress = YES;
            [self.attachmentsCollection insertItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
        }
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    if (scrollView == self.attachmentsCollection)
    {
        if (isBackPaginationInProgress)
        {
            MXKAttachment *attachment = self.attachments.firstObject;
            self.complete = ![self.delegate attachmentsViewController:self paginateAttachmentBefore:attachment.event.eventId];
        }
        else
        {
            [self refreshCurrentVisibleCell];
        }
    }
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return [[UIScreen mainScreen] bounds].size;
}

#pragma mark - Movie Player

- (void)moviePlayerPlaybackDidFinishWithErrorNotification:(NSNotification *)notification
{
    NSDictionary *notificationUserInfo = [notification userInfo];
    NSError *mediaPlayerError = [notificationUserInfo objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey];

    if (mediaPlayerError){
        NSLog(@"[MXKAttachmentsVC] Playback failed with error description: %@", [mediaPlayerError localizedDescription]);
        // Notify MatrixKit user
        [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:mediaPlayerError];
    }
}

#pragma mark - Gesture recognizer

- (void)onCollectionViewCellTap:(UIGestureRecognizer*)gestureRecognizer
{
    MXKMediaCollectionViewCell *selectedCell;
    
    UIView *view = gestureRecognizer.view;
    if ([view isKindOfClass:[MXKMediaCollectionViewCell class]])
    {
        selectedCell = (MXKMediaCollectionViewCell*)view;
    }
    
    // Notify the collection view delegate a cell has been selected.
    if (selectedCell && selectedCell.tag < attachments.count)
    {
        [self collectionView:self.attachmentsCollection didSelectItemAtIndexPath:[NSIndexPath indexPathForItem:(isBackPaginationInProgress ? selectedCell.tag + 1: selectedCell.tag) inSection:0]];
    }
}

- (void)onCollectionViewCellLongPress:(UIGestureRecognizer*)gestureRecognizer
{
    MXKMediaCollectionViewCell *selectedCell;
    
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan)
    {
        UIView *view = gestureRecognizer.view;
        if ([view isKindOfClass:[MXKMediaCollectionViewCell class]])
        {
            selectedCell = (MXKMediaCollectionViewCell*)view;
        }
    }
    
    // Notify the collection view delegate a cell has been selected.
    if (selectedCell && selectedCell.tag < attachments.count)
    {
        MXKAttachment *attachment = attachments[selectedCell.tag];
        
        if (currentAlert)
        {
            [currentAlert dismiss:NO];
            currentAlert = nil;
        }
        
        __weak __typeof(self) weakSelf = self;
        currentAlert = [[MXKAlert alloc] initWithTitle:nil message:nil style:MXKAlertStyleActionSheet];
        
        [currentAlert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"save"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
            
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            strongSelf->currentAlert = nil;
            
            [strongSelf startActivityIndicator];
            
            [attachment save:^{
                
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf stopActivityIndicator];
                
            } failure:^(NSError *error) {
                
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf stopActivityIndicator];
                
                // Notify MatrixKit user
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error];
                
            }];
            
        }];
        
        [currentAlert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"copy"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
            
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            strongSelf->currentAlert = nil;
            
            [strongSelf startActivityIndicator];
            
            [attachment copy:^{
                
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf stopActivityIndicator];
                
            } failure:^(NSError *error) {
                
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf stopActivityIndicator];
                
                // Notify MatrixKit user
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error];
                
            }];
        }];
        
        [currentAlert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"share"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
            
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            strongSelf->currentAlert = nil;
            
            [strongSelf startActivityIndicator];
            
            [attachment prepareShare:^(NSURL *fileURL) {
                
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf stopActivityIndicator];
                
                strongSelf->documentInteractionController = [UIDocumentInteractionController interactionControllerWithURL:fileURL];
                [strongSelf->documentInteractionController setDelegate:strongSelf];
                currentSharedAttachment = attachment;
                
                if (![strongSelf->documentInteractionController presentOptionsMenuFromRect:strongSelf.view.frame inView:strongSelf.view animated:YES])
                {
                    strongSelf->documentInteractionController = nil;
                    [attachment onShareEnded];
                    currentSharedAttachment = nil;
                }
                
            } failure:^(NSError *error) {
                
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf stopActivityIndicator];
                
                // Notify MatrixKit user
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error];
                
            }];
            
        }];
        
        if ([MXKMediaManager existingDownloaderWithOutputFilePath:attachment.cacheFilePath])
        {
            [currentAlert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel_download"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
                
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                strongSelf->currentAlert = nil;
                
                // Get again the loader
                MXKMediaLoader *loader = [MXKMediaManager existingDownloaderWithOutputFilePath:attachment.cacheFilePath];
                if (loader)
                {
                    [loader cancel];
                }
            }];
        }
        
        currentAlert.cancelButtonIndex = [currentAlert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {
            
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            strongSelf->currentAlert = nil;
            
        }];
        
        currentAlert.sourceView = _attachmentsCollection;
        [currentAlert showInViewController:self];
    }
}

#pragma mark - UIDocumentInteractionControllerDelegate

- (UIViewController *)documentInteractionControllerViewControllerForPreview: (UIDocumentInteractionController *) controller
{
    return self;
}

// Preview presented/dismissed on document.  Use to set up any HI underneath.
- (void)documentInteractionControllerWillBeginPreview:(UIDocumentInteractionController *)controller
{
    documentInteractionController = controller;
}

- (void)documentInteractionControllerDidEndPreview:(UIDocumentInteractionController *)controller
{
    documentInteractionController = nil;
    if (currentSharedAttachment)
    {
        [currentSharedAttachment onShareEnded];
        currentSharedAttachment = nil;
    }
}

- (void)documentInteractionControllerDidDismissOptionsMenu:(UIDocumentInteractionController *)controller
{
    documentInteractionController = nil;
    if (currentSharedAttachment)
    {
        [currentSharedAttachment onShareEnded];
        currentSharedAttachment = nil;
    }
}

- (void)documentInteractionControllerDidDismissOpenInMenu:(UIDocumentInteractionController *)controller
{
    documentInteractionController = nil;
    if (currentSharedAttachment)
    {
        [currentSharedAttachment onShareEnded];
        currentSharedAttachment = nil;
    }
}

@end
