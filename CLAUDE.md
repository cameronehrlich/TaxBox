# TaxBox - Document Organization System

## Purpose & Vision

TaxBox is a macOS application designed to simplify tax document management for individuals and small businesses. The app provides a streamlined way to organize, categorize, and track financial documents throughout the year, making tax preparation significantly less stressful.

## Core Problem Being Solved

Tax season often becomes overwhelming because documents are scattered across emails, downloads folders, physical papers, and various digital locations. TaxBox centralizes this chaos by providing:

- A single repository for all tax-related documents
- Year-based organization that aligns with tax filing periods  
- Metadata tracking to remember context about each document
- Quick search and filtering to find specific documents when needed

## Key Design Principles

### 1. Simplicity First
The app should be immediately understandable. Drag files in, add some context, and they're organized. No complex workflows or extensive configuration required.

### 2. Local-First Storage
All documents remain on the user's machine in `~/Documents/Tax Box/`. No cloud dependencies, no privacy concerns, full user control over their sensitive financial data.

### 3. Non-Destructive Operations
By default, the app copies files rather than moving them, ensuring users never lose their originals. This safety-first approach builds trust with sensitive financial documents.

### 4. Transparent File Organization
Documents are stored in a human-readable folder structure (`Tax Box/YEAR/filename`). Users can browse their documents directly in Finder if needed, without requiring the app.

### 5. Contextual Metadata
Each document gets a companion `.meta.json` file containing:
- Descriptive name (beyond just filename)
- Dollar amount (for receipts, invoices, etc.)
- Notes for context
- Status tracking (Done, Waiting, Needs Doc, Ready)
- Import timestamp and source path

## User Workflow

### Primary Use Case
1. User receives a tax document (PDF receipt, bank statement, W2, etc.)
2. Drags the file(s) into TaxBox window
3. Prompted for quick metadata (name, amount, notes, status, year)
4. Document is copied to organized location with metadata preserved
5. Throughout the year, user can search, filter, and track document status
6. At tax time, all documents are organized and ready

### Secondary Features
- **Year-based filtering**: Focus on specific tax years
- **Status tracking**: Know what's complete vs. what's still needed
- **Amount totaling**: Quick sum of expenses/income in view
- **Quick preview**: Click to open any document
- **Bulk operations**: Import multiple documents at once
- **Search**: Find documents by name, filename, or notes

## Technical Approach

### Architecture Philosophy
- **SwiftUI-native**: Modern macOS development approach
- **Single source of truth**: File system is authoritative, app reads current state
- **Minimal dependencies**: Standard Apple frameworks only
- **Defensive programming**: Graceful handling of missing files or metadata

### Data Storage Strategy
- **File-based**: No database required, just organized folders
- **Sidecar pattern**: Metadata stored alongside documents as JSON
- **Self-healing**: App regenerates state from file system on each launch
- **Portable**: Entire document tree can be backed up, moved, or shared

## Future Considerations

### Potential Enhancements
- **OCR Integration**: Auto-extract amounts and dates from documents
- **Category System**: Deductible vs. non-deductible, income vs. expense
- **Report Generation**: Year-end summaries for tax preparers
- **Receipt Scanning**: Direct camera/scanner integration
- **Reminder System**: Notifications for missing expected documents
- **Multi-user Support**: Separate spaces for household members
- **Backup Integration**: Time Machine awareness, cloud backup guidance

### Integration Opportunities
- **Tax Software Export**: Generate compatible import files
- **Financial App Sync**: Pull documents from banks/brokers
- **Email Monitoring**: Auto-import from specific senders
- **Cloud Storage**: Optional sync with iCloud/Dropbox for backup

## Success Metrics

The app succeeds when users:
- Feel confident they haven't missed any tax documents
- Can find any document within seconds
- Spend less time preparing for their tax appointment
- Trust the system with their sensitive financial documents
- Actually use it consistently throughout the year (not just at tax time)

## Maintenance & Evolution

This app should evolve based on:
- **User feedback**: What's confusing? What's missing?
- **Tax law changes**: New document types, new requirements
- **macOS updates**: Adopt new OS features as they become available
- **Performance needs**: Optimize for users with thousands of documents
- **Security requirements**: Enhanced protection for sensitive data

## Development Guidelines

When extending this app:
1. **Preserve simplicity**: Every feature should have clear value
2. **Respect user data**: Never lose or corrupt documents
3. **Maintain transparency**: User should understand what's happening
4. **Follow Apple HIG**: Native look, feel, and behavior
5. **Test with real data**: PDFs, images, various file types
6. **Consider accessibility**: VoiceOver, keyboard navigation, etc.

## Testing Considerations

### Critical Test Scenarios
- Importing files with existing names (collision handling)
- Missing sidecar files (graceful degradation)
- Corrupted metadata (recovery behavior)
- Large file imports (performance)
- Special characters in filenames
- Year boundary transitions
- Concurrent file system changes

### Edge Cases to Handle
- Files deleted outside the app
- Metadata files without corresponding documents
- Read-only file permissions
- Full disk scenarios
- Network drives (if supported)
- Symbolic links and aliases

---

*This document serves as the north star for TaxBox development. Implementation details will change, but these core principles and goals should guide all decisions.*

## Implementation Notes & Lessons Learned

### Current Project Structure
- **Location**: `/Users/cameronehrlich/TaxBox/ios/TaxBox/`
- **Platform**: macOS 13+ with SwiftUI
- **Xcode Project**: Full Xcode project setup with entitlements for file access

### Key Implementation Details

#### Fixed Issues
1. **Hashable Conformance**: `Sidecar` struct needs `Hashable` for SwiftUI table selection
2. **Amount Field Editing Crash**: Don't call `reload()` during field editing - update items in place
3. **Memory Leak Prevention**: Thumbnail generation should track loading state to prevent repeated calls
4. **Modal Dismissal**: Sheet dismissal requires explicit `showSheet = false` in completion handler
5. **Finder Tags**: Disabled due to sandboxing limitations - requires additional entitlements

#### UI/UX Improvements Made
- **Status Filter Visibility**: 
  - Sidebar shows selected filter with accent color background and checkmark
  - Toolbar shows active filter badge with quick clear button
  - Section renamed to "Status Filter" for clarity
- **Right-Click Delete**: Context menu for deleting selected files and revealing in Finder
- **Year Formatting**: Fixed comma in year stepper (use `String(year)` not default formatting)

#### Architecture Decisions
- **Update Pattern**: Update individual items in array rather than full reload to preserve UI state
- **File Operations**: Default to copy (safer) with toggle for move operations
- **Delete Operations**: Remove both file and `.meta.json` sidecar together

### Future Design Considerations

#### "Indie Developer Vibe" Ideas (Not Yet Implemented)
- Warmer color palette while maintaining system integration
- Friendly empty states with helpful illustrations
- Subtle animations on drag/drop and state changes
- More conversational microcopy in prompts and messages
- Rounded corners and softer shadows throughout
- Optional fun statistics view (e.g., "You've organized 47 documents this year! 🎉")

#### Technical Debt & Improvements
- Consider implementing proper diffing for array updates
- Add error recovery UI for file operation failures
- Implement undo/redo for destructive operations
- Cache thumbnails more efficiently
- Add keyboard shortcuts for common operations

### Git Repository Setup
- Repository initialized with comprehensive `.gitignore` for macOS/Xcode
- All project files committed with descriptive initial commit
- Ready for version control and collaboration

### Testing Reminders
- Test with hundreds of files for performance
- Verify behavior when `~/Documents/Tax Box/` doesn't exist
- Test drag-and-drop with various file types
- Ensure proper cleanup of orphaned `.meta.json` files
- Verify amount field handles edge cases (negative numbers, very large values)