#!/bin/sh

set -e

# This script handles matrix JSON file downloading and path resolution
# It supports both URL downloading and local file paths, with gzip support

# Default configuration
MATRIX_URL=""
MATRIX_FILE=""
CONFIG_DIR="/hivesense/config"

# Parse command-line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --matrix-url=*)
            MATRIX_URL="${1#*=}"
            ;;
        --matrix-file=*)
            MATRIX_FILE="${1#*=}"
            ;;
        --config-dir=*)
            CONFIG_DIR="${1#*=}"
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Function to extract filename from URL
get_filename_from_url() {
    url="$1"
    # Extract filename from URL, handling query strings
    basename "${url%%\?*}"
}

# Function to download file if not cached
download_if_needed() {
    url="$1"
    filename="$2"
    filepath="${CONFIG_DIR}/${filename}"
    
    if [ -f "$filepath" ]; then
        echo "Matrix file already cached at: $filepath" >&2
        echo "$filepath"
        return 0
    fi
    
    echo "Downloading matrix from: $url" >&2
    echo "Saving to: $filepath" >&2
    
    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"
    
    # Download with resume support
    if curl -L -C - -o "$filepath" "$url" >&2 2>&1; then
        echo "Successfully downloaded matrix file" >&2
        echo "$filepath"
        return 0
    else
        echo "ERROR: Failed to download matrix from $url" >&2
        rm -f "$filepath"  # Clean up partial download
        return 1
    fi
}

# Main logic
main() {
    # Check that only one option is set
    if [ -n "$MATRIX_URL" ] && [ -n "$MATRIX_FILE" ]; then
        echo "ERROR: Both HIVESENSE_MATRIX_JSON_URL and HIVESENSE_MATRIX_JSON_FILE are set. Please use only one." >&2
        exit 1
    fi
    
    if [ -n "$MATRIX_URL" ]; then
        # URL mode: download if needed
        filename=$(get_filename_from_url "$MATRIX_URL")
        if [ -z "$filename" ]; then
            echo "ERROR: Could not extract filename from URL: $MATRIX_URL" >&2
            exit 1
        fi
        
        if ! filepath=$(download_if_needed "$MATRIX_URL" "$filename"); then
            exit 1
        fi
        
        # Export the resolved path for use by install_app.sh
        export HIVESENSE_REDUCED_MATRIX_JSON="$filepath"
        
    elif [ -n "$MATRIX_FILE" ]; then
        # File mode: use provided path
        if [ ! -f "$MATRIX_FILE" ]; then
            echo "ERROR: Matrix file not found at: $MATRIX_FILE" >&2
            exit 1
        fi
        
        echo "Using local matrix file: $MATRIX_FILE" >&2
        export HIVESENSE_REDUCED_MATRIX_JSON="$MATRIX_FILE"
        
    else
        # No matrix configuration
        echo "No matrix JSON configured (neither URL nor FILE specified)" >&2
        export HIVESENSE_REDUCED_MATRIX_JSON=""
    fi
    
    # Output the final path for logging
    if [ -n "$HIVESENSE_REDUCED_MATRIX_JSON" ]; then
        echo "Matrix JSON path resolved to: $HIVESENSE_REDUCED_MATRIX_JSON" >&2
        
        # Check if it's gzipped
        case "$HIVESENSE_REDUCED_MATRIX_JSON" in
            *.gz)
                echo "Matrix file is gzipped, will decompress on-the-fly when loading" >&2
                ;;
        esac
    fi
}

# Run main function
main