//
//  NSObject+RACSelectorSignal.m
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/18/13.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "NSObject+RACSelectorSignal.h"
#import <ReactiveObjC/EXTRuntimeExtensions.h>
#import "NSInvocation+RACTypeParsing.h"
#import "NSObject+RACDeallocating.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACSubject.h"
#import "RACTuple.h"
#import "NSObject+RACDescription.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const RACSelectorSignalErrorDomain = @"RACSelectorSignalErrorDomain";
const NSInteger RACSelectorSignalErrorMethodSwizzlingRace = 1;

static NSString * const RACSignalForSelectorAliasPrefix = @"rac_alias_";
static NSString * const RACSignalForSelectorAliasOfOriginalPrefix = @"rac_runtime_";
static NSString * const RACSubclassSuffix = @"_RACSelectorSignal";
static void *RACSubclassAssociationKey = &RACSubclassAssociationKey;

static NSMutableSet *swizzledClasses() {
	static NSMutableSet *set;
	static dispatch_once_t pred;
	
	dispatch_once(&pred, ^{
		set = [[NSMutableSet alloc] init];
	});

	return set;
}

@implementation NSObject (RACSelectorSignal)

static void RACSwizzleForwardInvocation(Class class) {
	Class superclass = class_getSuperclass(class);
	SEL forwardInvocationSEL = @selector(forwardInvocation:);

	// Set up a new version of -forwardInvocation:.
	//
	// If the selector has been passed to -rac_signalForSelector:, invoke
	// the aliased method, and forward the arguments to any attached signals.
	//
	// If the selector has not been passed to -rac_signalForSelector:,
	// invoke any existing implementation of -forwardInvocation:. If there
	// was no existing implementation, throw an unrecognized selector
	// exception.
	id newForwardInvocation = ^(id self, NSInvocation *invocation) {
		BOOL forward = NO;

		SEL originalSelector = invocation.selector;
		SEL aliasSelector = RACAliasForSelector(originalSelector);
		SEL aliasOfOriginalSelector = RACAliasOfOriginalForSelector(originalSelector);

		RACSubject* subject = objc_getAssociatedObject(self, aliasSelector);

		Class baseClass = object_getClass(self);

		if ([baseClass instancesRespondToSelector:aliasOfOriginalSelector]) {
			Method xchgMethod = class_getInstanceMethod(baseClass, aliasOfOriginalSelector);
			IMP oldImpl = class_replaceMethod(baseClass, originalSelector, method_getImplementation(xchgMethod), method_getTypeEncoding(xchgMethod));
			invocation.selector = originalSelector;
			[invocation invoke];
			class_replaceMethod(baseClass, originalSelector, oldImpl, method_getTypeEncoding(xchgMethod));
		} else if ([superclass instancesRespondToSelector:originalSelector]) {
			Method method = class_getInstanceMethod(superclass, originalSelector);
			IMP impl = method_getImplementation(method);

			if (impl != _objc_msgForward) {
				class_replaceMethod(baseClass, aliasSelector, impl, method_getTypeEncoding(method));
				invocation.selector = aliasSelector;
				[invocation invoke];
			} else {
				forward = YES;
			}
		} else {
			forward = subject == nil;
		}

		if (forward) {
			struct objc_super target = {
				.super_class = superclass,
				.receiver = self,
			};

			void*(*superForwardInvocation)(struct objc_super *, SEL, NSInvocation*) = (__typeof__(superForwardInvocation)) objc_msgSendSuper;
			superForwardInvocation(&target, forwardInvocationSEL, invocation);
		}

		if (subject != nil) {
			[subject sendNext:invocation.rac_argumentsTuple];
		}
	};

	class_replaceMethod(class, forwardInvocationSEL, imp_implementationWithBlock(newForwardInvocation), "v@:@");
}

static void RACSwizzleRespondsToSelector(Class class) {
	Class superclass = class_getSuperclass(class);
	SEL respondsToSelectorSEL = @selector(respondsToSelector:);

	// Set up a new version of -respondsToSelector: that returns YES for methods
	// added by -rac_signalForSelector:.
	//
	// If the selector has a method defined on the receiver's actual class, and
	// if that method's implementation is _objc_msgForward, then returns whether
	// the instance has a signal for the selector.
	// Otherwise, call the original -respondsToSelector:.
	id newRespondsToSelector = ^ BOOL (id self, SEL selector) {
		Method method = rac_getImmediateInstanceMethod(class, selector);

		if (method != NULL && method_getImplementation(method) == _objc_msgForward) {
			SEL aliasSelector = RACAliasForSelector(selector);
			if (objc_getAssociatedObject(self, aliasSelector) != nil) return YES;
		}

		struct objc_super target = {
			.super_class = superclass,
			.receiver = self,
		};

		BOOL(*superRespondsToSelector)(struct objc_super *, SEL, SEL) = (__typeof__(superRespondsToSelector)) objc_msgSendSuper;

		return superRespondsToSelector(&target, respondsToSelectorSEL, selector);
	};

	class_replaceMethod(class, respondsToSelectorSEL, imp_implementationWithBlock(newRespondsToSelector), "v@::");
}

static void RACSwizzleGetClass(Class class, Class statedClass) {
	SEL selector = @selector(class);
	Method method = class_getInstanceMethod(class, selector);
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, selector, newIMP, method_getTypeEncoding(method));
}

static void RACSwizzleMethodSignatureForSelector(Class class) {
	IMP newIMP = imp_implementationWithBlock(^(id self, SEL selector) {
		// Don't send the -class message to the receiver because we've changed
		// that to return the original class.
		Class actualClass = object_getClass(self);
		Method method = class_getInstanceMethod(actualClass, selector);
		if (method == NULL) {
			// Messages that the original class dynamically implements fall
			// here.
			//
			// Call the original class' -methodSignatureForSelector:.
			struct objc_super target = {
				.super_class = class_getSuperclass(class),
				.receiver = self,
			};
			NSMethodSignature * (*messageSend)(struct objc_super *, SEL, SEL) = (__typeof__(messageSend))objc_msgSendSuper;
			return messageSend(&target, @selector(methodSignatureForSelector:), selector);
		}

		char const *encoding = method_getTypeEncoding(method);
		return [NSMethodSignature signatureWithObjCTypes:encoding];
	});

	SEL selector = @selector(methodSignatureForSelector:);
	Method methodSignatureForSelectorMethod = class_getInstanceMethod(class, selector);
	class_replaceMethod(class, selector, newIMP, method_getTypeEncoding(methodSignatureForSelectorMethod));
}

// It's hard to tell which struct return types use _objc_msgForward, and
// which use _objc_msgForward_stret instead, so just exclude all struct, array,
// union, complex and vector return types.
static void RACCheckTypeEncoding(const char *typeEncoding) {
#if !NS_BLOCK_ASSERTIONS
	// Some types, including vector types, are not encoded. In these cases the
	// signature starts with the size of the argument frame.
	NSCAssert(*typeEncoding < '1' || *typeEncoding > '9', @"unknown method return type not supported in type encoding: %s", typeEncoding);
	NSCAssert(strstr(typeEncoding, "(") != typeEncoding, @"union method return type not supported");
	NSCAssert(strstr(typeEncoding, "{") != typeEncoding, @"struct method return type not supported");
	NSCAssert(strstr(typeEncoding, "[") != typeEncoding, @"array method return type not supported");
	NSCAssert(strstr(typeEncoding, @encode(_Complex float)) != typeEncoding, @"complex float method return type not supported");
	NSCAssert(strstr(typeEncoding, @encode(_Complex double)) != typeEncoding, @"complex double method return type not supported");
	NSCAssert(strstr(typeEncoding, @encode(_Complex long double)) != typeEncoding, @"complex long double method return type not supported");

#endif // !NS_BLOCK_ASSERTIONS
}

static RACSignal *NSObjectRACSignalForSelector(NSObject *self, SEL selector, Protocol *protocol) {
	SEL aliasSelector = RACAliasForSelector(selector);

	@synchronized (self) {
		RACSubject *subject = objc_getAssociatedObject(self, aliasSelector);
		if (subject != nil) return subject;

		Class class = RACSwizzleClass(self);
		NSCAssert(class != nil, @"Could not swizzle class of %@", self);

		subject = [[RACSubject subject] setNameWithFormat:@"%@ -rac_signalForSelector: %s", RACDescription(self), sel_getName(selector)];
		objc_setAssociatedObject(self, aliasSelector, subject, OBJC_ASSOCIATION_RETAIN);

		[self.rac_deallocDisposable addDisposable:[RACDisposable disposableWithBlock:^{
			[subject sendCompleted];
		}]];

		Method targetMethod = class_getInstanceMethod(class, selector);
		if (targetMethod == NULL) {
			const char *typeEncoding;
			if (protocol == NULL) {
				typeEncoding = RACSignatureForUndefinedSelector(selector);
			} else {
				// Look for the selector as an optional instance method.
				struct objc_method_description methodDescription = protocol_getMethodDescription(protocol, selector, NO, YES);

				if (methodDescription.name == NULL) {
					// Then fall back to looking for a required instance
					// method.
					methodDescription = protocol_getMethodDescription(protocol, selector, YES, YES);
					NSCAssert(methodDescription.name != NULL, @"Selector %@ does not exist in <%s>", NSStringFromSelector(selector), protocol_getName(protocol));
				}

				typeEncoding = methodDescription.types;
			}

			RACCheckTypeEncoding(typeEncoding);

			// Define the selector to call -forwardInvocation:.
			if (!class_addMethod(class, selector, _objc_msgForward, typeEncoding)) {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"A race condition occurred implementing %@ on class %@", nil), NSStringFromSelector(selector), class],
					NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Invoke -rac_signalForSelector: again to override the implementation.", nil)
				};

				return [RACSignal error:[NSError errorWithDomain:RACSelectorSignalErrorDomain code:RACSelectorSignalErrorMethodSwizzlingRace userInfo:userInfo]];
			}
		} else if (method_getImplementation(targetMethod) != _objc_msgForward) {
			// Make a method alias for the existing method implementation.
			const char *typeEncoding = method_getTypeEncoding(targetMethod);

			RACCheckTypeEncoding(typeEncoding);

			Method existingMethod = rac_getImmediateInstanceMethod(class, selector);

			if (existingMethod) {
				SEL sel = RACAliasOfOriginalForSelector(selector);
				BOOL addedAlias __attribute__((unused)) = class_addMethod(class, sel, method_getImplementation(existingMethod), typeEncoding);
				NSCAssert(addedAlias, @"Existing external implementation for %@ has already been copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(sel), class);
			}

			// Redefine the selector to call -forwardInvocation:.
			class_replaceMethod(class, selector, _objc_msgForward, method_getTypeEncoding(targetMethod));
		}

		return subject;
	}
}

static SEL RACAliasOfOriginalForSelector(SEL originalSelector) {
	NSString *selectorName = NSStringFromSelector(originalSelector);
	return NSSelectorFromString([RACSignalForSelectorAliasOfOriginalPrefix stringByAppendingString:selectorName]);
}

static SEL RACAliasForSelector(SEL originalSelector) {
	NSString *selectorName = NSStringFromSelector(originalSelector);
	return NSSelectorFromString([RACSignalForSelectorAliasPrefix stringByAppendingString:selectorName]);
}

static const char *RACSignatureForUndefinedSelector(SEL selector) {
	const char *name = sel_getName(selector);
	NSMutableString *signature = [NSMutableString stringWithString:@"v@:"];

	while ((name = strchr(name, ':')) != NULL) {
		[signature appendString:@"@"];
		name++;
	}

	return signature.UTF8String;
}

static Class RACSwizzleClass(NSObject *self) {
	Class statedClass = self.class;
	Class baseClass = object_getClass(self);

	// The "known dynamic subclass" is the subclass generated by RAC.
	// It's stored as an associated object on every instance that's already
	// been swizzled, so that even if something else swizzles the class of
	// this instance, we can still access the RAC generated subclass.
	Class knownDynamicSubclass = objc_getAssociatedObject(self, RACSubclassAssociationKey);
	if (knownDynamicSubclass != Nil) return knownDynamicSubclass;

	NSString *className = NSStringFromClass(baseClass);

	if (statedClass != baseClass) {
		// If the class is already lying about what it is, it's probably a KVO
		// dynamic subclass or something else that we shouldn't subclass
		// ourselves.
		//
		// Just swizzle -forwardInvocation: in-place. Since the object's class
		// was almost certainly dynamically changed, we shouldn't see another of
		// these classes in the hierarchy.
		//
		// Additionally, swizzle -respondsToSelector: because the default
		// implementation may be ignorant of methods added to this class.
		@synchronized (swizzledClasses()) {
			if (![swizzledClasses() containsObject:className]) {
				RACSwizzleForwardInvocation(baseClass);
				RACSwizzleRespondsToSelector(baseClass);
				RACSwizzleGetClass(baseClass, statedClass);
				RACSwizzleGetClass(object_getClass(baseClass), statedClass);
				RACSwizzleMethodSignatureForSelector(baseClass);
				[swizzledClasses() addObject:className];
			}
		}

		return baseClass;
	}

	const char *subclassName = [className stringByAppendingString:RACSubclassSuffix].UTF8String;
	Class subclass = objc_getClass(subclassName);

	if (subclass == nil) {
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) return nil;

		RACSwizzleForwardInvocation(subclass);
		RACSwizzleRespondsToSelector(subclass);

		RACSwizzleGetClass(subclass, statedClass);
		RACSwizzleGetClass(object_getClass(subclass), statedClass);

		RACSwizzleMethodSignatureForSelector(subclass);

		objc_registerClassPair(subclass);
	}

	object_setClass(self, subclass);
	objc_setAssociatedObject(self, RACSubclassAssociationKey, subclass, OBJC_ASSOCIATION_ASSIGN);
	return subclass;
}

- (RACSignal *)rac_signalForSelector:(SEL)selector {
	NSCParameterAssert(selector != NULL);

	return NSObjectRACSignalForSelector(self, selector, NULL);
}

- (RACSignal *)rac_signalForSelector:(SEL)selector fromProtocol:(Protocol *)protocol {
	NSCParameterAssert(selector != NULL);
	NSCParameterAssert(protocol != NULL);

	return NSObjectRACSignalForSelector(self, selector, protocol);
}

@end