//
//  ImpHFSAnalyzer.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-31.
//

#import <Foundation/Foundation.h>

@class ImpHFSVolume;

@interface ImpHFSAnalyzer : NSObject

@property(copy) NSURL *_Nonnull sourceDevice;
@property TextEncoding hfsTextEncoding;

@property ImpHFSVolume *_Nonnull sourceVolume;

- (bool)performAnalysisOrReturnError:(NSError *_Nullable *_Nonnull) outError;

@end
