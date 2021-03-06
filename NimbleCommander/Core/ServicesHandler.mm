// Copyright (C) 2018-2019 Michael Kazakov. Subject to GNU General Public License version 3.
#include "ServicesHandler.h"
#include <VFS/Native.h>
#include <NimbleCommander/States/MainWindowController.h>
#include <NimbleCommander/States/FilePanels/MainWindowFilePanelState.h>
#include <NimbleCommander/States/FilePanels/PanelController.h>
#include <Utility/StringExtras.h>

namespace nc::core {

ServicesHandler::ServicesHandler( std::function<NCMainWindowController*()> _window_provider ):
    m_WindowProvider( move(_window_provider) )
{
    assert( m_WindowProvider );
}

static NSURL* ExtractFirstURL(NSPasteboard *_pboard)
{
    for( NSPasteboardItem *item in _pboard.pasteboardItems )
        if( auto url_string = [item stringForType:@"public.file-url"] )
            if( auto url = [NSURL URLWithString:url_string] )
                return url;
    return nil;
}
    
void ServicesHandler::OpenFolder(NSPasteboard *_pboard,
                                 [[maybe_unused]] NSString *_user_data,
                                 [[maybe_unused]] __strong NSString **_error)
{
    auto url = ExtractFirstURL(_pboard);
    if( !url )
        return;
    
    auto fs_representation = url.fileSystemRepresentation;
    if( !fs_representation )
        return;
    
    if( VFSNativeHost::SharedHost()->IsDirectory(fs_representation, 0) )
        GoToFolder(fs_representation);
}
    
void ServicesHandler::GoToFolder(const std::string &_path)
{
    auto host = VFSNativeHost::SharedHost();
    if( auto wnd = m_WindowProvider() ) {
        auto ctx = std::make_shared<panel::DirectoryChangeRequest>();
        ctx->RequestedDirectory = _path;
        ctx->VFS = host;
        ctx->InitiatedByUser = true;
        [wnd.filePanelsState.activePanelController GoToDirWithContext:ctx];
    }
}

static std::pair<std::string, std::vector<std::string>>
    ExtractFirstDirectoryAndFilenamesInside(const std::vector<std::string>&_paths)
{
    std::string directory;
    std::vector<std::string> filenames;
    for( auto &i:_paths ) {
        if( i.empty() )
            continue;
        
        boost::filesystem::path p = i;
        if( directory.empty() ) {
            directory = p.filename() == "." ?
                p.parent_path().parent_path().native() : // .../abra/cadabra/ -> .../abra/cadabra
                p.parent_path().native();                // .../abra/cadabra  -> .../abra
        }
        if( i.front() == '/' && i.back() != '/' && i != "/" )
            filenames.emplace_back( boost::filesystem::path(i).filename().native() );
    }

    return make_pair(move(directory), move(filenames));
}

static bool IsASingleDirectoryPath(const std::vector<std::string>&_paths)
{
    return _paths.size() == 1 && VFSNativeHost::SharedHost()->IsDirectory(_paths[0].c_str(), 0);
}
    
void ServicesHandler::RevealItem(NSPasteboard *_pboard,
                                 [[maybe_unused]] NSString *_user_data,
                                 [[maybe_unused]] __strong NSString **_error)
{
    std::vector<std::string> paths;
    for( NSPasteboardItem *item in _pboard.pasteboardItems ) {
        if( auto url_string = [item stringForType:@"public.file-url"] ) {
            if( auto url = [NSURL URLWithString:url_string] )
                if( auto path = url.fileSystemRepresentation  )
                    paths.emplace_back( path );
        }
        else if( auto path_string = [item stringForType:@"NSFilenamesPboardType"]  ) {
            if( auto fs = path_string.fileSystemRepresentation  )
                paths.emplace_back( fs );
        }
    }
    RevealItems(paths);
}
    
void ServicesHandler::OpenFiles(NSArray<NSString *> *_paths)
{
    std::vector<std::string> paths;
    for( NSString *path_string in _paths ) {
        // WTF Cocoa??
        if( [path_string isEqualToString:@"YES"] )
            continue;
        if( auto fs = path_string.fileSystemRepresentationSafe )
            paths.emplace_back( fs );
    }
    
    if( IsASingleDirectoryPath(paths) )
        GoToFolder(paths[0]);
    else
        RevealItems(paths);
}
    
void ServicesHandler::RevealItems(const std::vector<std::string> &_paths)
{
    auto [directory, filenames] = ExtractFirstDirectoryAndFilenamesInside(_paths);
    if( directory.empty() || filenames.empty() )
        return;
    
    if( auto wnd = m_WindowProvider() ) {
        auto ctx = std::make_shared<panel::DirectoryChangeRequest>();
        ctx->RequestedDirectory = directory;
        ctx->VFS = VFSNativeHost::SharedHost();
        ctx->RequestFocusedEntry = filenames.front();
        if( filenames.size() > 1 )
            ctx->RequestSelectedEntries = filenames;
        ctx->InitiatedByUser = true;
        [wnd.filePanelsState.activePanelController GoToDirWithContext:ctx];
    }
}
    
}
