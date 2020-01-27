
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BROWN='\033[0;33m'
BLUE='\033[0;34m'

function info() {
    echo -e "${BLUE}INFO: ${1}${NC}"
}

function warn() {
    echo -e "${BROWN}WARN: ${1}${NC}"
}

function success() {
    echo -e "${GREEN}SUCCESS: ${1}${NC}"
}

function error() {
    echo -e "${RED}ERROR: ${1}${NC}"
}
