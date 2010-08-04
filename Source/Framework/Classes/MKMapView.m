//
//  MKMapView.m
//  MapKit
//
//  Created by Rick Fillion on 7/11/10.
//  Copyright 2010 Centrix.ca. All rights reserved.
//

#import "MKMapView.h"
#import "JSON.h"
#import <MapKit/MKUserLocation.h>
#import "MKUserLocation+Private.h"
#import <MapKit/MKCircleView.h>
#import <MapKit/MKCircle.h>
#import <MapKit/MKPolyline.h>
#import <MapKit/MKPolygon.h>
#import <MapKit/MKAnnotationView.h>
#import <MapKit/MKPointAnnotation.h>
#import "MKMapView+DelegateWrappers.h"
#import "MKMapView+WebViewIntegration.h"

@interface MKMapView (Private)

- (void)customInit;

@end


@implementation MKMapView

@synthesize delegate, mapType, showsUserLocation;


- (id)initWithFrame:(NSRect)frame {
    if (self = [super initWithFrame:frame]) 
    {
        [self customInit];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)decoder
{
    if (self = [super initWithCoder:decoder])
    {
        [self customInit];
        [self setMapType:[decoder decodeIntegerForKey:@"mapType"]];
        [self setShowsUserLocation:[decoder decodeBoolForKey:@"showsUserLocation"]];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder
{
    [super encodeWithCoder:encoder];
    //[encoder encodeObject:webView forKey:@"webView"];
    [encoder encodeInteger:[self mapType] forKey:@"mapType"];
    [encoder encodeBool:[self showsUserLocation] forKey:@"showsUserLocation"];
}

- (void)customInit
{
    // Initialization code here.
    if (!webView)
    {
        webView = [[WebView alloc] initWithFrame:[self bounds]];
    }

    [webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [webView setFrameLoadDelegate:self];
    
    // Create the overlay data structures
    overlays = [[NSMutableArray array] retain];
    overlayViews = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    overlayScriptObjects = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    // Create the annotation data structures
    annotations = [[NSMutableArray array] retain];
    selectedAnnotations = [[NSMutableArray array] retain];
    annotationViews = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    annotationScriptObjects = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    // TODO : make this suck less.
    NSBundle *frameworkBundle = [NSBundle bundleForClass:[self class]];
    NSString *indexPath = [frameworkBundle pathForResource:@"MapKit" ofType:@"html"];
    [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:[NSURL fileURLWithPath:indexPath]]]; 
    [[[webView mainFrame] frameView] setAllowsScrolling:NO];
    [self addSubview:webView];
    
    // Create a user location
    userLocation = [MKUserLocation new];
    
    // Get CoreLocation Manager
    locationManager = [CLLocationManager new];
    locationManager.delegate = self;
    locationManager.desiredAccuracy = kCLLocationAccuracyBest;
}

- (void)dealloc
{
    [webView setFrameLoadDelegate:nil];
    delegate = nil;
    [webView removeFromSuperview];
    [webView autorelease];
    [locationManager stopUpdatingLocation];
    [locationManager release];
    [userLocation release];
    [overlays release];
    CFRelease(overlayViews);
    overlayViews = NULL;
    CFRelease(overlayScriptObjects);
    overlayScriptObjects = NULL;
    [annotations release];
    [selectedAnnotations release];
    CFRelease(annotationViews);
    annotationViews = NULL;
    CFRelease(annotationScriptObjects);
    annotationScriptObjects = NULL;
    [super dealloc];
}



- (void)setFrame:(NSRect)frameRect
{
    [self delegateRegionWillChangeAnimated:NO];
    [super setFrame:frameRect];
    [self willChangeValueForKey:@"region"];
    [self didChangeValueForKey:@"region"];
    [self willChangeValueForKey:@"centerCoordinate"];
    [self didChangeValueForKey:@"centerCoordinate"];
    [self delegateRegionDidChangeAnimated:NO];
}

- (void)setMapType:(MKMapType)type
{
    mapType = type;
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    NSArray *args = [NSArray arrayWithObject:[NSNumber numberWithInt:mapType]];
    [webScriptObject callWebScriptMethod:@"setMapType" withArguments:args];
}

- (CLLocationCoordinate2D)centerCoordinate
{
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    NSNumber *latitude = nil; 
    NSNumber *longitude = nil;
    NSString *json = [webScriptObject evaluateWebScript:@"getCenterCoordinate()"];
    if ([json isKindOfClass:[NSString class]])
    {
        NSDictionary *latlong = [json JSONValue];
        latitude = [latlong objectForKey:@"latitude"];
        longitude = [latlong objectForKey:@"longitude"];
    }

    CLLocationCoordinate2D centerCoordinate;
    centerCoordinate.latitude = [latitude doubleValue];
    centerCoordinate.longitude = [longitude doubleValue];
    return centerCoordinate;
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coordinate
{
    [self setCenterCoordinate:coordinate animated: NO];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coordinate animated:(BOOL)animated
{
    [self willChangeValueForKey:@"region"];
    NSArray *args = [NSArray arrayWithObjects:
                     [NSNumber numberWithDouble:coordinate.latitude],
                     [NSNumber numberWithDouble:coordinate.longitude],
                     [NSNumber numberWithBool:animated], 
                      nil];
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    [webScriptObject callWebScriptMethod:@"setCenterCoordinateAnimated" withArguments:args];
    [self didChangeValueForKey:@"region"];
    hasSetCenterCoordinate = YES;
}


- (MKCoordinateRegion)region
{
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    NSString *json = [webScriptObject evaluateWebScript:@"getRegion()"];
    NSDictionary *regionDict = [json JSONValue];
    
    NSNumber *centerLatitude = [regionDict valueForKeyPath:@"center.latitude"];
    NSNumber *centerLongitude = [regionDict valueForKeyPath:@"center.longitude"];
    NSNumber *latitudeDelta = [regionDict objectForKey:@"latitudeDelta"];
    NSNumber *longitudeDelta = [regionDict objectForKey:@"longitudeDelta"];
    
    MKCoordinateRegion region;
    region.center.longitude = [centerLongitude doubleValue];
    region.center.latitude = [centerLatitude doubleValue];
    region.span.latitudeDelta = [latitudeDelta doubleValue];
    region.span.longitudeDelta = [longitudeDelta doubleValue];
    return region;
}

- (void)setRegion:(MKCoordinateRegion)region
{
    [self setRegion:region animated: NO];
}

- (void)setRegion:(MKCoordinateRegion)region animated:(BOOL)animated
{
    [self delegateRegionWillChangeAnimated:animated];
    [self willChangeValueForKey:@"centerCoordinate"];
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    NSArray *args = [NSArray arrayWithObjects:
                     [NSNumber numberWithDouble:region.center.latitude], 
                     [NSNumber numberWithDouble:region.center.longitude], 
                     [NSNumber numberWithDouble:region.span.latitudeDelta], 
                     [NSNumber numberWithDouble:region.span.longitudeDelta],
                     [NSNumber numberWithBool:animated], 
                     nil];
    [webScriptObject callWebScriptMethod:@"setRegionAnimated" withArguments:args];
    [self didChangeValueForKey:@"centerCoordinate"];
    [self delegateRegionDidChangeAnimated:animated];
}

- (void)setShowsUserLocation:(BOOL)show
{
    showsUserLocation = show;
    if (showsUserLocation)
    {
        [userLocation _setUpdating:YES];
        [locationManager startUpdatingLocation];
    }
    else 
    {
        [self setUserLocationMarkerVisible: NO];
        [userLocation _setUpdating:NO];
        [locationManager stopUpdatingLocation];
        [userLocation _setLocation:nil];
    }
}

- (BOOL)isUserLocationVisible
{
    if (!self.showsUserLocation || !userLocation.location)
        return NO;
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    NSNumber *visible = [webScriptObject callWebScriptMethod:@"isUserLocationVisible" withArguments:[NSArray array]];
    return [visible boolValue];
}

#pragma mark Overlays

- (NSArray *)overlays
{
    return [[overlays copy] autorelease];
}

- (void)addOverlay:(id < MKOverlay >)overlay
{
    [self insertOverlay:overlay atIndex:[overlays count]];
}

- (void)addOverlays:(NSArray *)someOverlays
{
    for (id<MKOverlay>overlay in someOverlays)
    {
        [self addOverlay: overlay];
    }
}

- (void)exchangeOverlayAtIndex:(NSUInteger)index1 withOverlayAtIndex:(NSUInteger)index2
{
    if (index1 >= [overlays count] || index2 >= [overlays count])
    {
        NSLog(@"exchangeOverlayAtIndex: either index1 or index2 is above the bounds of the overlays array.");
        return;
    }
    
    id < MKOverlay > overlay1 = [[overlays objectAtIndex: index1] retain];
    id < MKOverlay > overlay2 = [[overlays objectAtIndex: index2] retain];
    [overlays replaceObjectAtIndex:index2 withObject:overlay1];
    [overlays replaceObjectAtIndex:index1 withObject:overlay2];
    [overlay1 release];
    [overlay2 release];
    [self updateOverlayZIndexes];
}

- (void)insertOverlay:(id < MKOverlay >)overlay aboveOverlay:(id < MKOverlay >)sibling
{
    if (![overlays containsObject:sibling])
        return;
    
    NSUInteger indexOfSibling = [overlays indexOfObject:sibling];
    [self insertOverlay:overlay atIndex: indexOfSibling+1];
}

- (void)insertOverlay:(id < MKOverlay >)overlay atIndex:(NSUInteger)index
{
    // check if maybe we already have this one.
    if ([overlays containsObject:overlay])
        return;
    
    // Make sure we have a valid index.
    if (index > [overlays count])
        index = [overlays count];
    
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    
    MKOverlayView *overlayView = nil;
    if ([self.delegate respondsToSelector:@selector(mapView:viewForOverlay:)])
        overlayView = [self.delegate mapView:self viewForOverlay:overlay];
    if (!overlayView)
    {
        // TODO: Handle the case where we have no view
        NSLog(@"Wasn't able to create a MKOverlayView for overlay: %@", overlay);
        return;
    }
    
    WebScriptObject *overlayScriptObject = [overlayView overlayScriptObjectFromMapSriptObject:webScriptObject];
    
    [overlays insertObject:overlay atIndex:index];
    CFDictionarySetValue(overlayViews, overlay, overlayView);
    CFDictionarySetValue(overlayScriptObjects, overlay, overlayScriptObject);
    
    NSArray *args = [NSArray arrayWithObject:overlayScriptObject];
    [webScriptObject callWebScriptMethod:@"addOverlay" withArguments:args];
    [overlayView draw:overlayScriptObject];
    
    [self updateOverlayZIndexes];
    
    // TODO: refactor how this works so that we can send one batch call
    // when they called addOverlays:
    [self delegateDidAddOverlayViews:[NSArray arrayWithObject:overlayView]];
}

- (void)insertOverlay:(id < MKOverlay >)overlay belowOverlay:(id < MKOverlay >)sibling
{
    if (![overlays containsObject:sibling])
        return;
    
    NSUInteger indexOfSibling = [overlays indexOfObject:sibling];
    [self insertOverlay:overlay atIndex: indexOfSibling];    
}

- (void)removeOverlay:(id < MKOverlay >)overlay
{
    if (![overlays containsObject:overlay])
        return;
    
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    WebScriptObject *overlayScriptObject = (WebScriptObject *)CFDictionaryGetValue(overlayScriptObjects, overlay);
    NSArray *args = [NSArray arrayWithObject:overlayScriptObject];
    [webScriptObject callWebScriptMethod:@"removeOverlay" withArguments:args];

    CFDictionaryRemoveValue(overlayViews, overlay);
    CFDictionaryRemoveValue(overlayScriptObjects, overlay);

    [overlays removeObject:overlay];
    [self updateOverlayZIndexes];
}

- (void)removeOverlays:(NSArray *)someOverlays
{
    for (id<MKOverlay>overlay in someOverlays)
    {
        [self removeOverlay: overlay];
    }
}

- (MKOverlayView *)viewForOverlay:(id < MKOverlay >)overlay
{
    if (![overlays containsObject:overlay])
        return nil;
    return (MKOverlayView *)CFDictionaryGetValue(overlayViews, overlay);
}

#pragma mark Annotations

- (NSArray *)annotations
{
    return [[annotations copy] autorelease];
}

- (void)addAnnotation:(id < MKAnnotation >)annotation
{
    // check if maybe we already have this one.
    if ([annotations containsObject:annotation])
        return;
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    
    MKAnnotationView *annotationView = nil;
    if ([self.delegate respondsToSelector:@selector(mapView:viewForAnnotation:)])
        annotationView = [self.delegate mapView:self viewForAnnotation:annotation];
    if (!annotationView)
    {
        // TODO: Handle the case where we have no view
        NSLog(@"Wasn't able to create a MKAnnotationView for annotation: %@", annotation);
        return;
    }
    
    WebScriptObject *annotationScriptObject = [annotationView overlayScriptObjectFromMapSriptObject:webScriptObject];
    
    [annotations addObject:annotation];
    CFDictionarySetValue(annotationViews, annotation, annotationView);
    CFDictionarySetValue(annotationScriptObjects, annotation, annotationScriptObject);
    
    NSArray *args = [NSArray arrayWithObject:annotationScriptObject];
    [webScriptObject callWebScriptMethod:@"addAnnotation" withArguments:args];
    [annotationView draw:annotationScriptObject];
    
    // TODO: refactor how this works so that we can send one batch call
    // when they called addAnnotations:
    [self delegateDidAddAnnotationViews:[NSArray arrayWithObject:annotationView]];
}

- (void)addAnnotations:(NSArray *)someAnnotations
{
    for (id<MKAnnotation>annotation in someAnnotations)
    {
        [self addAnnotation: annotation];
    }
}

- (void)removeAnnotation:(id < MKAnnotation >)annotation
{
    if (![annotations containsObject:annotation])
        return;
    
    WebScriptObject *webScriptObject = [webView windowScriptObject];
    WebScriptObject *annotationScriptObject = (WebScriptObject *)CFDictionaryGetValue(annotationScriptObjects, annotation);
    NSArray *args = [NSArray arrayWithObject:annotationScriptObject];
    [webScriptObject callWebScriptMethod:@"removeAnnotation" withArguments:args];
    
    CFDictionaryRemoveValue(annotationViews, annotation);
    CFDictionaryRemoveValue(annotationScriptObjects, annotation);
    
    [annotations removeObject:annotation];
}

- (void)removeAnnotations:(NSArray *)someAnnotations
{
    for (id<MKAnnotation>annotation in someAnnotations)
    {
        [self removeAnnotation: annotation];
    }
}

- (MKAnnotationView *)viewForAnnotation:(id < MKAnnotation >)annotation
{
    if (![annotations containsObject:annotation])
        return nil;
    return (MKAnnotationView *)CFDictionaryGetValue(annotationViews, annotation);
}

- (MKAnnotationView *)dequeueReusableAnnotationViewWithIdentifier:(NSString *)identifier
{
    // Unsupported for now.
    return nil; 
}

- (void)selectAnnotation:(id < MKAnnotation >)annotation animated:(BOOL)animated
{
    if ([selectedAnnotations containsObject:annotation])
        return;
    // TODO : probably want to do something here...
    id view = (id)CFDictionaryGetValue(annotationViews, annotation);
    [self delegateDidSelectAnnotationView:view];
    [selectedAnnotations addObject:annotation];
}

- (void)deselectAnnotation:(id < MKAnnotation >)annotation animated:(BOOL)animated
{
    // TODO : animate this if called for.
    if (![selectedAnnotations containsObject:annotation])
        return;
    // TODO : probably want to do something here...
    id view = (id)CFDictionaryGetValue(annotationViews, annotation);
    [self delegateDidDeselectAnnotationView:view];
    [selectedAnnotations removeObject:annotation];
}

- (NSArray *)selectedAnnotations
{
    return [[selectedAnnotations copy] autorelease];
}

- (void)setSelectedAnnotations:(NSArray *)someAnnotations
{
    // Deselect whatever was selected
    NSArray *oldSelectedAnnotations = [self selectedAnnotations];
    for (id <MKAnnotation> annotation in oldSelectedAnnotations)
    {
        [self deselectAnnotation:annotation animated:NO];
    }
    NSMutableArray *newSelectedAnnotations = [NSMutableArray arrayWithArray: [[someAnnotations copy] autorelease]];
    [selectedAnnotations release];
    selectedAnnotations = [newSelectedAnnotations retain];
    
    // If it's manually set and there's more than one, you only select the first according to the docs.
    if ([selectedAnnotations count] > 0)
        [self selectAnnotation:[selectedAnnotations objectAtIndex:0] animated:NO];
}

#pragma mark Faked Properties

- (BOOL)isScrollEnabled
{
    return YES;
}

- (void)setScrollEnabled:(BOOL)scrollEnabled
{
    if (!scrollEnabled)
        NSLog(@"setting scrollEnabled to NO on MKMapView not supported.");
}

- (BOOL)isZoomEnabled
{
    return YES;
}

- (void)setZoomEnabled:(BOOL)zoomEnabled
{
    if (!zoomEnabled)
        NSLog(@"setting zoomEnabled to NO on MKMapView not supported");
}



#pragma mark CoreLocationManagerDelegate

- (void) locationManager: (CLLocationManager *)manager
     didUpdateToLocation: (CLLocation *)newLocation
            fromLocation: (CLLocation *)oldLocation
{
    if (!hasSetCenterCoordinate)
        [self setCenterCoordinate:newLocation.coordinate];
    [userLocation _setLocation:newLocation];
    [self updateUserLocationMarkerWithLocaton:newLocation];
    [self setUserLocationMarkerVisible:YES];
    [self delegateDidUpdateUserLocation];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    [self delegateDidFailToLocateUserWithError:error];
    [self setUserLocationMarkerVisible:NO];
}

#pragma mark WebFrameLoadDelegate

- (void)webView:(WebView *)sender didClearWindowObject:(WebScriptObject *)windowScriptObject forFrame:(WebFrame *)frame
{
    [windowScriptObject setValue:windowScriptObject forKey:@"WindowScriptObject"];
    [windowScriptObject setValue:self forKey:@"MKMapView"];
}


- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    // CoreLocation can sometimes trigger before the page has even finished loading.
    if (self.showsUserLocation && userLocation.location)
    {
        [self locationManager: locationManager didUpdateToLocation: userLocation.location fromLocation:nil];
    }
    
    // In case we have to resume state from NSCoding
    [self setMapType:[self mapType]];
    [self setShowsUserLocation:[self showsUserLocation]];
}

@end
