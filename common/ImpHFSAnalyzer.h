//
//  ImpHFSAnalyzer.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-31.
//

#import <Foundation/Foundation.h>

@class ImpSourceVolume;

@interface ImpHFSAnalyzer : NSObject

@property(copy) NSURL *_Nonnull sourceDevice;
@property TextEncoding hfsTextEncoding;

@property ImpSourceVolume *_Nonnull sourceVolume;

- (bool)performAnalysisOrReturnError:(NSError *_Nullable *_Nonnull) outError;

@end
