from personalBestCache import personalBestCache
from userStatsCache import userStatsCache

from common.ddog import datadogClient
from common.files import fileBuffer, fileLocks
from common.web import schiavo

try:
    with open("version") as f:
        VERSION = f.read().strip()
except:
    VERSION = "Unknown"
ACHIEVEMENTS_VERSION = 1

DATADOG_PREFIX = "lets"
BOT_NAME = "Aika"
db = None
redis = None
conf = None
application = None
pool = None
pascoa = {}

busyThreads = 0
debug = False
sentry = False

# Top plays for std vn/rx
topPlays = [0., 0.]

# Cache and objects
fLocks = fileLocks.fileLocks()
userStatsCache = userStatsCache()
personalBestCache = personalBestCache()
fileBuffers = fileBuffer.buffersList()
dog = datadogClient.datadogClient()
schiavo = schiavo.schiavo()
achievementClasses = {}
