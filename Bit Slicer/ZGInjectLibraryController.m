/*
 * Created by Mayur Pawashe on 2/21/15.
 *
 * Copyright (c) 2015 zgcoder
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "ZGInjectLibraryController.h"
#import "ZGBreakPointController.h"
#import "ZGUtilities.h"
#import "ZGThreadStates.h"
#import "ZGVirtualMemory.h"
#import "ZGMachBinary.h"
#import "ZGDebuggerUtilities.h"
#import "ZGBreakPoint.h"
#import "ZGInstruction.h"
#import "NSArrayAdditions.h"
#include <dlfcn.h>

@implementation ZGInjectLibraryController
{
	x86_thread_state_t _originalThreadState;
	mach_msg_type_number_t _threadStateCount;
	
	zg_x86_vector_state_t _originalVectorState;
	mach_msg_type_number_t _vectorStateCount;
	
	thread_act_array_t _threadList;
	mach_msg_type_number_t _threadListCount;
	
	ZGMemoryAddress _codeAddress;
	ZGMemorySize _codeSize;
	
	ZGMemoryAddress _stackAddress;
	ZGMemorySize _stackSize;
	
	ZGMemoryAddress _dataAddress;
	ZGMemorySize _dataSize;
	
	ZGBreakPointController *_breakPointController;
	ZGInstruction *_haltedInstruction;
	NSString *_path;
	NSArray *_machBinariesBeforeInjecting;
	BOOL _secondPass;
	
	ZGInjectLibraryCompletionHandler _completionHandler;
}

// Pauses current execution of the process and adds a breakpoint at the current instruction pointer
// If we don't add a breakpoint, things will get screwy (presumably because the debug flags will not be set properly?)
- (void)injectDynamicLibraryAtPath:(NSString *)path inProcess:(ZGProcess *)process breakPointController:(ZGBreakPointController *)breakPointController completionHandler:(ZGInjectLibraryCompletionHandler)completionHandler
{
	_breakPointController = breakPointController;
	_path = [path copy];
	
	_completionHandler = completionHandler;
	
	// Fields we'll need later; initialize to 0
	_secondPass = NO;
	_codeAddress = 0;
	_codeSize = 0;
	_stackAddress = 0;
	_stackSize = 0;
	_dataAddress = 0;
	_dataSize = 0;
	_machBinariesBeforeInjecting = nil;
	
	ZGMemoryMap processTask = process.processTask;
	
	ZGSuspendTask(processTask);
	
	_threadList = NULL;
	_threadListCount = 0;
	
	void (^handleFailure)(void) =  ^{
		if (self->_threadList != NULL)
		{
			ZGDeallocateMemory(current_task(), (mach_vm_address_t)self->_threadList, self->_threadListCount * sizeof(thread_act_t));
		}
		ZGResumeTask(processTask);
		completionHandler(NO, nil);
	};
	
	if (task_threads(processTask, &_threadList, &_threadListCount) != KERN_SUCCESS)
	{
		ZG_LOG(@"ERROR: task_threads failed on removing watchpoint");
		handleFailure();
		return;
	}
	
	if (_threadListCount == 0)
	{
		ZG_LOG(@"ERROR: threadListCount is 0..");
		handleFailure();
		return;
	}
	
	thread_act_t mainThread = _threadList[0];
	
	x86_thread_state_t threadState;
	mach_msg_type_number_t threadStateCount;
	if (!ZGGetGeneralThreadState(&threadState, mainThread, &threadStateCount))
	{
		ZG_LOG(@"ERROR: Grabbing thread state failed %s", __PRETTY_FUNCTION__);
		handleFailure();
		return;
	}
	
	ZGMemoryAddress instructionPointer = process.is64Bit ? threadState.uts.ts64.__rip : threadState.uts.ts32.__eip;
	
	_machBinariesBeforeInjecting = [ZGMachBinary machBinariesInProcess:process];
	_haltedInstruction = [ZGDebuggerUtilities findInstructionBeforeAddress:instructionPointer + 0x1 inProcess:process withBreakPoints:breakPointController.breakPoints machBinaries:_machBinariesBeforeInjecting];
	
	if (_haltedInstruction == nil)
	{
		ZG_LOG(@"Failed fetching current instruction at 0x%llX..", instructionPointer);
		handleFailure();
		return;
	}
	
	ZGMemoryAddress basePointer = process.is64Bit ? threadState.uts.ts64.__rbp : threadState.uts.ts32.__ebp;
	
	if (![breakPointController addBreakPointOnInstruction:_haltedInstruction inProcess:process thread:mainThread basePointer:basePointer delegate:self])
	{
		ZG_LOG(@"ERROR: Failed to set up breakpoint at IP %s", __PRETTY_FUNCTION__);
		handleFailure();
		return;
	}
	
	ZGResumeTask(processTask);
}

- (void)breakPointDidHit:(ZGBreakPoint *)breakPoint
{
	ZGProcess *process = breakPoint.process;
	ZGMemoryMap processTask = process.processTask;
	thread_act_t thread = breakPoint.thread;
	
	if (!_secondPass)
	{
		_secondPass = YES;
		
		ZGInstruction *endOfCodeInstruction = nil;
		
		void (^handleFailure)(void) = ^{
			if (self->_codeAddress != 0)
			{
				ZGDeallocateMemory(processTask, self->_codeAddress, self->_codeSize);
			}
			
			if (self->_dataAddress != 0)
			{
				ZGDeallocateMemory(processTask, self->_dataAddress, self->_dataSize);
			}
			
			if (self->_stackAddress != 0)
			{
				ZGDeallocateMemory(processTask, self->_stackAddress, self->_stackSize);
			}
			
			if (self->_haltedInstruction != nil)
			{
				[self->_breakPointController removeBreakPointOnInstruction:self->_haltedInstruction inProcess:process];
			}
			
			if (endOfCodeInstruction != nil)
			{
				[self->_breakPointController removeBreakPointOnInstruction:endOfCodeInstruction inProcess:process];
			}
			
			if (self->_threadList != NULL)
			{
				ZGDeallocateMemory(current_task(), (mach_vm_address_t)self->_threadList, self->_threadListCount * sizeof(thread_act_t));
			}
			
			[self->_breakPointController resumeFromBreakPoint:breakPoint];
			
			dispatch_async(dispatch_get_main_queue(), ^{
				self->_completionHandler(NO, nil);
			});
		};
		
		// Inject our code that will call dlopen
		// After it's injected, change the stack and instruction pointers to our own
		
		NSNumber *dlopenAddressNumber = [process findSymbol:@"dlopen" withPartialSymbolOwnerName:@"/usr/bin/dyld" requiringExactMatch:YES pastAddress:0x0 allowsWrappingToBeginning:NO];
		
		if (dlopenAddressNumber == nil)
		{
			ZG_LOG(@"Failed to find dlopen address");
			handleFailure();
			return;
		}
		
		ZGMemoryAddress pageSize = NSPageSize(); // default
		ZGPageSize(processTask, &pageSize);
		
		ZGMemoryAddress codeAddress = 0;
		ZGMemorySize codeSize = pageSize;
		if (!ZGAllocateMemory(processTask, &codeAddress, codeSize))
		{
			ZG_LOG(@"Failed allocating memory for code");
			handleFailure();
			return;
		}
		
		_codeAddress = codeAddress;
		_codeSize = codeSize;
		
		if (!ZGProtect(processTask, codeAddress, codeSize, VM_PROT_READ))
		{
			ZG_LOG(@"Failed setting memory protection for code");
			handleFailure();
			return;
		}
		
		ZGMemoryAddress stackAddress = 0;
		ZGMemorySize stackSize = pageSize * 16;
		if (!ZGAllocateMemory(processTask, &stackAddress, stackSize))
		{
			ZG_LOG(@"Failed allocating memory for stack");
			handleFailure();
			return;
		}
		
		_stackAddress = stackAddress;
		_stackSize = stackSize;
		
		if (!ZGProtect(processTask, stackAddress, stackSize, VM_PROT_READ | VM_PROT_WRITE))
		{
			ZG_LOG(@"Failed setting memory protection for stack");
			handleFailure();
			return;
		}
		
		ZGMemoryAddress dataAddress = 0;
		ZGMemorySize dataSize = pageSize * 2;
		if (!ZGAllocateMemory(processTask, &dataAddress, dataSize))
		{
			ZG_LOG(@"Failed allocating memory for data");
			handleFailure();
			return;
		}
		
		_dataAddress = dataAddress;
		_dataSize = dataSize;
		
		if (!ZGProtect(processTask, dataAddress, dataSize, VM_PROT_READ | VM_PROT_WRITE))
		{
			ZG_LOG(@"Failed setting memory protection for data");
			handleFailure();
			return;
		}
		
		const char *pathCString = [_path UTF8String];
		if (pathCString == NULL)
		{
			ZG_LOG(@"Failed to get C string from path string: %@", _path);
			handleFailure();
			return;
		}
		
		size_t pathCStringLength = strlen(pathCString);
		ZGMemoryAddress libraryPathAddress = dataAddress + 0x8;
		
		if (libraryPathAddress + pathCStringLength + 1 > dataAddress + dataSize)
		{
			ZG_LOG(@"Library path is too long to fit into allocated data");
			handleFailure();
			return;
		}
		
		if (!ZGWriteBytes(processTask, libraryPathAddress, pathCString, pathCStringLength + 1))
		{
			ZG_LOG(@"Failed writing C path string to memory");
			handleFailure();
			return;
		}
		
		void *nopBuffer = malloc(codeSize);
		assert(nopBuffer != NULL);
		
		memset(nopBuffer, 0x90, codeSize);
		
		if (!ZGWriteBytesIgnoringProtection(processTask, codeAddress, nopBuffer, codeSize))
		{
			ZG_LOG(@"Failed to NOP instruction bytes");
			handleFailure();
			return;
		}
		
		free(nopBuffer);
		
		thread_act_t mainThread = _threadList[0];
		
		x86_thread_state_t threadState;
		mach_msg_type_number_t threadStateCount;
		if (!ZGGetGeneralThreadState(&threadState, mainThread, &threadStateCount))
		{
			ZG_LOG(@"ERROR: Grabbing thread state failed %s", __PRETTY_FUNCTION__);
			handleFailure();
			return;
		}
		
		_originalThreadState = threadState;
		_threadStateCount = threadStateCount;
		
		zg_x86_vector_state_t vectorState;
		mach_msg_type_number_t vectorStateCount;
		if (!ZGGetVectorThreadState(&vectorState, mainThread, &vectorStateCount, process.is64Bit, NULL))
		{
			ZG_LOG(@"ERROR: Grabbing vector state failed %s", __PRETTY_FUNCTION__);
			handleFailure();
			return;
		}
		
		_originalVectorState = vectorState;
		_vectorStateCount = vectorStateCount;
		
		for (mach_msg_type_number_t threadIndex = 0; threadIndex < _threadListCount; ++threadIndex)
		{
			if (threadIndex > 0 && thread_suspend(_threadList[threadIndex]) != KERN_SUCCESS)
			{
				NSLog(@"Failed suspending thread %u", _threadList[threadIndex]);
			}
		}
		
		const int dlopenMode = RTLD_NOW | RTLD_GLOBAL;
		
		NSArray *assemblyComponents = nil;
		if (!process.is64Bit)
		{
			assemblyComponents =
			@[@"sub esp, 0x8", [NSString stringWithFormat:@"push dword %d", dlopenMode], [NSString stringWithFormat:@"push dword %u", (ZG32BitMemoryAddress)libraryPathAddress], [NSString stringWithFormat:@"call dword %u",  dlopenAddressNumber.unsignedIntValue], [NSString stringWithFormat:@"mov ecx, dword %u", (ZG32BitMemoryAddress)dataAddress], @"mov [ecx], eax", @"add esp, 0x8"];
		}
		else
		{
			assemblyComponents =
			@[[NSString stringWithFormat:@"mov esi, %d", dlopenMode], [NSString stringWithFormat:@"mov rdi, qword %llu", libraryPathAddress], [NSString stringWithFormat:@"mov rcx, qword %llu", dlopenAddressNumber.unsignedLongLongValue], @"call rcx", [NSString stringWithFormat:@"mov rcx, qword %llu", dataAddress], @"mov [rcx], qword rax"];
		}
		
		NSString *assembly = [assemblyComponents componentsJoinedByString:@"\n"];
		
		NSError *assemblingError = nil;
		NSData *codeData = [ZGDebuggerUtilities assembleInstructionText:assembly atInstructionPointer:codeAddress usingArchitectureBits:process.pointerSize * 8 error:&assemblingError];
		if (assemblingError != nil)
		{
			ZG_LOG(@"Assembly error: %@", assemblingError);
			handleFailure();
			return;
		}
		
		if (!ZGWriteBytesIgnoringProtection(processTask, codeAddress, codeData.bytes, codeData.length))
		{
			ZG_LOG(@"Failed to write code into memory");
			handleFailure();
			return;
		}
		
		endOfCodeInstruction = [ZGDebuggerUtilities findInstructionBeforeAddress:codeAddress + codeData.length + 0x2 inProcess:process withBreakPoints:_breakPointController.breakPoints machBinaries:_machBinariesBeforeInjecting];
		if (![_breakPointController addBreakPointOnInstruction:endOfCodeInstruction inProcess:process condition:NULL delegate:self])
		{
			ZG_LOG(@"Failed to add breakpoint at 0x%llX", endOfCodeInstruction.variable.address);
			endOfCodeInstruction = nil;
			handleFailure();
			return;
		}
		
		if (!process.is64Bit)
		{
			threadState.uts.ts32.__eip = (ZG32BitMemoryAddress)codeAddress;
			threadState.uts.ts32.__esp = (ZG32BitMemoryAddress)(stackAddress + stackSize / 2);
		}
		else
		{
			threadState.uts.ts64.__rip = codeAddress;
			threadState.uts.ts64.__rsp = (stackAddress + stackSize / 2);
		}
		
		if (!ZGSetGeneralThreadState(&threadState, mainThread, threadStateCount))
		{
			ZG_LOG(@"Failed setting general thread state..");
			handleFailure();
			return;
		}
		
		[_breakPointController removeBreakPointOnInstruction:_haltedInstruction inProcess:process];
		_haltedInstruction = endOfCodeInstruction;
		
		[_breakPointController resumeFromBreakPoint:breakPoint];
	}
	else
	{
		// Restore everything to the way it was before we ran our code
		BOOL success = YES;
		
		if (!ZGSetGeneralThreadState(&_originalThreadState, thread, _threadStateCount))
		{
			ZG_LOG(@"Failed to set thread state after breakpoint");
			success = NO;
		}
		
		if (!ZGSetVectorThreadState(&_originalVectorState, thread, _vectorStateCount, breakPoint.process.is64Bit))
		{
			ZG_LOG(@"Failed to set vector state after breakpoint");
			success = NO;
		}
		
		[_breakPointController removeBreakPointOnInstruction:_haltedInstruction inProcess:process];
		_haltedInstruction = nil;
		
		for (mach_msg_type_number_t threadIndex = 0; threadIndex < _threadListCount; ++threadIndex)
		{
			if (threadIndex > 0 && thread_resume(_threadList[threadIndex]) != KERN_SUCCESS)
			{
				NSLog(@"Failed resuming thread %u", _threadList[threadIndex]);
			}
		}
		
		ZGMemoryAddress *returnedAddress = NULL;
		ZGMemorySize returnedAddressSize = 0x8;
		if (!ZGReadBytes(processTask, _dataAddress, (void **)&returnedAddress, &returnedAddressSize))
		{
			ZG_LOG(@"Failed to read return address from dlopen");
			success = NO;
		}
		
		if (returnedAddressSize < 0x8)
		{
			ZG_LOG(@"dlopen read returned less bytes than expected");
			success = NO;
		}
		
		if (*returnedAddress == 0x0)
		{
			ZG_LOG(@"dlopen returned value NULL");
			success = NO;
		}
		
		ZGFreeBytes(returnedAddress, returnedAddressSize);
		
		if (!ZGDeallocateMemory(current_task(), (mach_vm_address_t)_threadList, _threadListCount * sizeof(thread_act_t)))
		{
			ZG_LOG(@"Failed to deallocate thread list in %s", __PRETTY_FUNCTION__);
		}
		
		if (!ZGDeallocateMemory(processTask, _codeAddress, _codeSize))
		{
			ZG_LOG(@"Failed to deallocate code in %s", __PRETTY_FUNCTION__);
		}
		
		if (!ZGDeallocateMemory(processTask, _stackAddress, _stackSize))
		{
			ZG_LOG(@"Failed to deallocate stack in %s", __PRETTY_FUNCTION__);
		}
		
		if (!ZGDeallocateMemory(processTask, _dataAddress, _dataSize))
		{
			ZG_LOG(@"Failed to deallocate data in %s", __PRETTY_FUNCTION__);
		}
		
		NSMutableDictionary *machBinaryDictionary = [[NSMutableDictionary alloc] init];
		for (ZGMachBinary *binary in _machBinariesBeforeInjecting)
		{
			[machBinaryDictionary setObject:binary forKey:@(binary.headerAddress)];
		}
		
		NSArray *newMachBinaries = [ZGMachBinary machBinariesInProcess:process];
		ZGMachBinary *newBinary = [newMachBinaries zgFirstObjectThatMatchesCondition:^BOOL(ZGMachBinary *binary) {
			if (machBinaryDictionary[@(binary.headerAddress)] != nil)
			{
				return NO;
			}
			
			return [[binary filePathInProcess:process] isEqualToString:self->_path];
		}];
		
		[_breakPointController resumeFromBreakPoint:breakPoint];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_completionHandler(success, newBinary);
		});
	}
}

@end