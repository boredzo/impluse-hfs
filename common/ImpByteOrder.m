//
//  ImpByteOrder.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-23.
//

#import "ImpByteOrder.h"

void _ImpSwapFinderFileInfoA(struct FInfo const *_Nonnull const srcPtr, struct FInfo *_Nonnull const dstPtr) {
	S(dstPtr->fdType, srcPtr->fdType);
	S(dstPtr->fdCreator, srcPtr->fdCreator);
	S(dstPtr->fdFlags, srcPtr->fdFlags);
	S(dstPtr->fdLocation.h, srcPtr->fdLocation.h);
	S(dstPtr->fdLocation.v, srcPtr->fdLocation.v);
	S(dstPtr->fdFldr, srcPtr->fdFldr);
}
void _ImpSwapFinderFileExtendedInfoA(struct FXInfo const *_Nonnull const srcPtr, struct FXInfo *_Nonnull const dstPtr) {
	S(dstPtr->fdIconID, srcPtr->fdIconID);
	S(dstPtr->fdReserved[0], srcPtr->fdReserved[0]);
	S(dstPtr->fdReserved[1], srcPtr->fdReserved[1]);
	S(dstPtr->fdReserved[2], srcPtr->fdReserved[2]);
	S(dstPtr->fdScript, srcPtr->fdScript);
	S(dstPtr->fdXFlags, srcPtr->fdXFlags);
	S(dstPtr->fdComment, srcPtr->fdComment);
	S(dstPtr->fdPutAway, srcPtr->fdPutAway);
}
void _ImpSwapFinderFolderInfoA(struct DInfo const *_Nonnull const srcPtr, struct DInfo *_Nonnull const dstPtr) {
	S(dstPtr->frRect.top, srcPtr->frRect.top);
	S(dstPtr->frRect.left, srcPtr->frRect.left);
	S(dstPtr->frRect.bottom, srcPtr->frRect.bottom);
	S(dstPtr->frRect.right, srcPtr->frRect.right);
	S(dstPtr->frFlags, srcPtr->frFlags);
	S(dstPtr->frLocation.h, srcPtr->frLocation.h);
	S(dstPtr->frLocation.v, srcPtr->frLocation.v);
	S(dstPtr->frView, srcPtr->frView);
}
void _ImpSwapFinderFolderExtendedInfoA(struct DXInfo const *_Nonnull const srcPtr, struct DXInfo *_Nonnull const dstPtr) {
	S(dstPtr->frScroll.h, srcPtr->frScroll.h);
	S(dstPtr->frScroll.v, srcPtr->frScroll.v);
	S(dstPtr->frOpenChain, srcPtr->frOpenChain);
	S(dstPtr->frScript, srcPtr->frScript);
	S(dstPtr->frXFlags, srcPtr->frXFlags);
	S(dstPtr->frComment, srcPtr->frComment);
	S(dstPtr->frPutAway, srcPtr->frPutAway);
}
