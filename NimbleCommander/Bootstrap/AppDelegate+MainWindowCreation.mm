// Copyright (C) 2018 Michael Kazakov. Subject to GNU General Public License version 3.
#include "AppDelegate+MainWindowCreation.h"
#include "AppDelegate.Private.h"
#include <VFSIcon/IconRepositoryImpl.h>
#include <VFSIcon/IconBuilderImpl.h>
#include <VFSIcon/QLThumbnailsCacheImpl.h>
#include <VFSIcon/WorkspaceIconsCacheImpl.h>
#include <VFSIcon/WorkspaceExtensionIconsCacheImpl.h>
#include <Utility/BriefOnDiskStorageImpl.h>
#include <VFSIcon/QLVFSThumbnailsCacheImpl.h>
#include <VFSIcon/VFSBundleIconsCacheImpl.h>
#include <NimbleCommander/States/MainWindowController.h>
#include <NimbleCommander/States/MainWindow.h>
#include <NimbleCommander/States/FilePanels/MainWindowFilePanelState.h>
#include <NimbleCommander/States/FilePanels/PanelController.h>
#include <NimbleCommander/States/FilePanels/PanelView.h>
#include <NimbleCommander/States/FilePanels/PanelViewHeader.h>
#include <NimbleCommander/States/FilePanels/PanelViewHeaderThemeImpl.h>
#include <NimbleCommander/States/FilePanels/PanelViewFooter.h>
#include <NimbleCommander/States/FilePanels/PanelViewFooterThemeImpl.h>
#include <NimbleCommander/States/FilePanels/PanelControllerActionsDispatcher.h>
#include <NimbleCommander/States/FilePanels/PanelControllerActions.h>
#include <NimbleCommander/States/FilePanels/StateActionsDispatcher.h>
#include <NimbleCommander/States/FilePanels/StateActions.h>
#include <Operations/Pool.h>
#include <Operations/AggregateProgressTracker.h>
#include "Config.h"
#include "ActivationManager.h"
#include <Habanero/CommonPaths.h>
#include <NimbleCommander/Core/SandboxManager.h>

static const auto g_ConfigRestoreLastWindowState = "filePanel.general.restoreLastWindowState";

namespace  {

enum class CreationContext {
    Default,
    ManualRestoration,
    SystemRestoration
};
    

class DirectoryAccessProviderImpl : public nc::panel::DirectoryAccessProvider
{
public:
    bool HasAccess(PanelController *_panel,
                   const std::string &_directory_path,
                   VFSHost &_host) override;
    bool RequestAccessSync(PanelController *_panel,
                           const std::string &_directory_path,
                           VFSHost &_host) override;
};

}

static bool RestoreFilePanelStateFromLastOpenedWindow(MainWindowFilePanelState *_state);

@implementation NCAppDelegate(MainWindowCreation)

- (NCMainWindow*) allocateMainWindow
{
    auto window = [[NCMainWindow alloc] init];
    if( !window )
        return nil;
    window.restorationClass = self.class;
    return window;
}

- (const nc::panel::PanelActionsMap &)panelActionsMap
{
    static auto actions_map = nc::panel::BuildPanelActionsMap(*self.networkConnectionsManager,
                                                              self.nativeFSManager);
    return actions_map;
}

- (const nc::panel::StateActionsMap &)stateActionsMap
{
    static auto actions_map = nc::panel::BuildStateActionsMap( *self.networkConnectionsManager );
    return actions_map;
}

- (std::unique_ptr<nc::vfsicon::IconRepository>) allocateIconRepository
{
    static const auto ql_cache = std::make_shared<nc::vfsicon::QLThumbnailsCacheImpl>();
    static const auto ws_cache = std::make_shared<nc::vfsicon::WorkspaceIconsCacheImpl>();
    static const auto ext_cache = std::make_shared<nc::vfsicon::WorkspaceExtensionIconsCacheImpl>();
    static const auto brief_storage = std::make_shared<nc::utility::BriefOnDiskStorageImpl>
        (CommonPaths::AppTemporaryDirectory(),
         nc::bootstrap::ActivationManager::BundleID() + ".ico"); 
    static const auto vfs_cache = std::make_shared<nc::vfsicon::QLVFSThumbnailsCacheImpl>(brief_storage);
    static const auto vfs_bi_cache = std::make_shared<nc::vfsicon::VFSBundleIconsCacheImpl>();
    
    static const auto icon_builder = std::make_shared<nc::vfsicon::IconBuilderImpl>(ql_cache,
                                                                           ws_cache,
                                                                           ext_cache,
                                                                           vfs_cache,
                                                                           vfs_bi_cache);
    const auto concurrency_per_repo = 4;
    using Que = nc::vfsicon::detail::IconRepositoryImplBase::GCDLimitedConcurrentQueue;
    
    return std::make_unique<nc::vfsicon::IconRepositoryImpl>
    (icon_builder, std::make_unique<Que>(concurrency_per_repo));
}

- (nc::panel::DirectoryAccessProvider&)directoryAccessProvider
{
    static auto provider = DirectoryAccessProviderImpl{};
    return provider;
}

- (nc::panel::ControllerStateJSONDecoder&)controllerStateJSONDecoder
{
    static auto decoder = nc::panel::ControllerStateJSONDecoder
        (self.nativeFSManager, self.vfsInstanceManager); 
    return decoder;
}

- (PanelView*) allocatePanelView
{    
    const auto header = [[NCPanelViewHeader alloc]
                         initWithFrame:NSRect()
                         theme:std::make_unique<nc::panel::HeaderThemeImpl>(self.themesManager)];
    const auto footer = [[NCPanelViewFooter alloc]
                         initWithFrame:NSRect()
                         theme:std::make_unique<nc::panel::FooterThemeImpl>(self.themesManager)];
    
    const auto pv_rect = NSMakeRect(0, 0, 100, 100);
    return [[PanelView alloc] initWithFrame:pv_rect
                             iconRepository:[self allocateIconRepository]
                                     header:header
                                     footer:footer];
}

- (PanelController*) allocatePanelController
{
    auto panel = [[PanelController alloc] initWithView:[self allocatePanelView]
                                               layouts:self.panelLayouts 
                                    vfsInstanceManager:self.vfsInstanceManager
                               directoryAccessProvider:self.directoryAccessProvider];    
    auto actions_dispatcher = [[NCPanelControllerActionsDispatcher alloc]
                               initWithController:panel
                               andActionsMap:self.panelActionsMap];
    [panel setNextAttachedResponder:actions_dispatcher];
    [panel.view addKeystrokeSink:actions_dispatcher
                withBasePriority:nc::panel::view::BiddingPriority::Low];
    panel.view.actionsDispatcher = actions_dispatcher;
    
    return panel;
}

static PanelController* PanelFactory()
{
    return [NCAppDelegate.me allocatePanelController];
}

- (MainWindowFilePanelState*)allocateFilePanelsWithFrame:(NSRect)_frame
                                               inContext:(CreationContext)_context
                                             withOpsPool:(nc::ops::Pool&)_operations_pool
{
    auto &ctrl_state_json_decoder = self.controllerStateJSONDecoder;
    if( _context == CreationContext::Default ) {
        return [[MainWindowFilePanelState alloc] initWithFrame:_frame
                                                       andPool:_operations_pool
                                            loadDefaultContent:true
                                                  panelFactory:PanelFactory
                                    controllerStateJSONDecoder:ctrl_state_json_decoder];
    }
    else if( _context == CreationContext::ManualRestoration ) {
        if( NCMainWindowController.canRestoreDefaultWindowStateFromLastOpenedWindow ) {
            auto state = [[MainWindowFilePanelState alloc] initWithFrame:_frame
                                                                 andPool:_operations_pool
                                                      loadDefaultContent:false
                                                            panelFactory:PanelFactory
                                              controllerStateJSONDecoder:ctrl_state_json_decoder];
            RestoreFilePanelStateFromLastOpenedWindow(state);
            [state loadDefaultPanelContent];
            return state;
        }
        else if( GlobalConfig().GetBool(g_ConfigRestoreLastWindowState) ) {
            auto state = [[MainWindowFilePanelState alloc] initWithFrame:_frame
                                                                 andPool:_operations_pool
                                                      loadDefaultContent:false
                                                            panelFactory:PanelFactory
                                              controllerStateJSONDecoder:ctrl_state_json_decoder];
            if( ![NCMainWindowController restoreDefaultWindowStateFromConfig:state] )
                [state loadDefaultPanelContent];
            return state;
        }
        else { // if we can't restore a window - fall back into a default creation context
            return [self allocateFilePanelsWithFrame:_frame
                                           inContext:CreationContext::Default
                                         withOpsPool:_operations_pool];
        }
    }
    else if( _context == CreationContext::SystemRestoration ) {
        return [[MainWindowFilePanelState alloc] initWithFrame:_frame
                                                       andPool:_operations_pool
                                            loadDefaultContent:false
                                                  panelFactory:PanelFactory
                                    controllerStateJSONDecoder:ctrl_state_json_decoder];
    }
    return nil;
}

- (NCMainWindowController*)allocateMainWindowInContext:(CreationContext)_context
{
    const auto window = [self allocateMainWindow];
    const auto frame = window.contentView.frame;
    const auto operations_pool =  nc::ops::Pool::Make();
    const auto window_controller = [[NCMainWindowController alloc] initWithWindow:window];
    window_controller.operationsPool = *operations_pool;
    self.operationsProgressTracker.AddPool(*operations_pool);
    
    const auto file_state = [self allocateFilePanelsWithFrame:frame
                                                    inContext:_context
                                                  withOpsPool:*operations_pool];
    auto actions_dispatcher = [[NCPanelsStateActionsDispatcher alloc]
                               initWithState:file_state
                               andActionsMap:self.stateActionsMap];
    actions_dispatcher.hasTerminal = nc::bootstrap::ActivationManager::Instance().HasTerminal();
    file_state.attachedResponder = actions_dispatcher;
    
    file_state.closedPanelsHistory = self.closedPanelsHistory;
    file_state.favoriteLocationsStorage = self.favoriteLocationsStorage;
    
    window_controller.filePanelsState = file_state;
    
    [self addMainWindow:window_controller];
    return window_controller;
}

- (NCMainWindowController*)allocateDefaultMainWindow
{
    return [self allocateMainWindowInContext:CreationContext::Default];
}

- (NCMainWindowController*)allocateMainWindowRestoredManually
{
    return [self allocateMainWindowInContext:CreationContext::ManualRestoration];
}

- (NCMainWindowController*)allocateMainWindowRestoredBySystem
{
    return [self allocateMainWindowInContext:CreationContext::SystemRestoration];
}

@end

static bool RestoreFilePanelStateFromLastOpenedWindow(MainWindowFilePanelState *_state)
{
    const auto last = NCMainWindowController.lastFocused;
    if( !last )
        return  false;
    
    const auto source_state = last.filePanelsState;
    [_state.leftPanelController copyOptionsFromController:source_state.leftPanelController];
    [_state.rightPanelController copyOptionsFromController:source_state.rightPanelController];
    return true;
}

bool DirectoryAccessProviderImpl::HasAccess(PanelController *_panel,
                                            const std::string &_directory_path,
                                            VFSHost &_host)
{
    // at this moment we (thankfully) care only about sanboxed versions 
    if constexpr ( nc::bootstrap::ActivationManager::Sandboxed() == false )
        return true;
    
    if( _host.IsNativeFS() )
        return SandboxManager::Instance().CanAccessFolder(_directory_path);            
    else
        return true;
}
    
bool DirectoryAccessProviderImpl::RequestAccessSync(PanelController *_panel,
                                                    const std::string &_directory_path,
                                                    VFSHost &_host)
{
    if constexpr ( nc::bootstrap::ActivationManager::Sandboxed() == false )
        return true;        
    
    if( _host.IsNativeFS() )
        return SandboxManager::EnsurePathAccess(_directory_path); // <-- the code smell see I here!        
    else
        return true;
    
    return true;
}