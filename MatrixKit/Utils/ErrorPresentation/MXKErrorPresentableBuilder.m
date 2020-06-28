/*
 Copyright 2018 New Vector Ltd
 
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

#import "MXKErrorPresentableBuilder.h"

#import "NSBundle+MatrixKit.h"
#import "MXKErrorViewModel.h"

@implementation MXKErrorPresentableBuilder

- (id <MXKErrorPresentable>)errorPresentableFromError:(NSError*)error
{
    // Ignore nil error or connection cancellation error
    if (!error || ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled))
    {
        return nil;
    }
    
    NSString *title = [error.userInfo valueForKey:NSLocalizedFailureReasonErrorKey];
    NSString *message = [error.userInfo valueForKey:NSLocalizedDescriptionKey];
    
    if (!title)
    {
        title = [NSBundle mxk_localizedStringForKey:@"error"];
    }
    
    if (!message)
    {
        message = [NSBundle mxk_localizedStringForKey:@"error_common_message"];
    }
    
    return  [[MXKErrorViewModel alloc] initWithTitle:title message:message];
}

- (id <MXKErrorPresentable>)commonErrorPresentable
{
    return  [[MXKErrorViewModel alloc] initWithTitle:[NSBundle mxk_localizedStringForKey:@"error"]
                                             message:[NSBundle mxk_localizedStringForKey:@"error_common_message"]];
}

@end
