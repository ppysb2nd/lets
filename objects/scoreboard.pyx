from typing import Optional
from objects import score
from common.ripple import userUtils
from constants import rankedStatuses
from common.constants import mods as modsEnum
from objects import glob
from common.constants import privileges
from common import generalUtils

class scoreboard:
    def __init__(self, username: str, gameMode: int, beatmap, setScores: bool = True, country: bool = False, friends: bool = False, mods: int = -1):
        """
        Initialize a leaderboard object
        username -- username of who's requesting the scoreboard. None if not known
        gameMode -- requested gameMode
        beatmap -- beatmap objecy relative to this leaderboard
        setScores -- if True, will get personal/top 50 scores automatically. Optional. Default: True
        """

        self.scores = []								# list containing all top 50 scores objects. First object is personal best
        self.totalScores = 0
        self.personalBestRank = -1						# our personal best rank, -1 if not found yet
        self.username: str = username						# username of who's requesting the scoreboard. None if not known
        self.userID: int = userUtils.getID(self.username)	# username's userID
        self.gameMode: int = gameMode						# requested gameMode
        self.beatmap = beatmap							# beatmap objecy relative to this leaderboard
        self.country: bool = country
        self.friends: bool = friends
        self.mods: int = mods
        if setScores:
            self.setScores()

    @staticmethod
    def buildQuery(params) -> str:
        return "{select} {joins} {country} {mods} {friends} {order} {limit}".format(**params)

    def getPersonalBestID(self) -> Optional[int]:
        if self.userID == 0:
            return None

        # Query parts
        cdef str select = ""
        cdef str joins = ""
        cdef str country = ""
        cdef str mods = ""
        cdef str friends = ""
        cdef str order = ""
        cdef str limit = ""
        select = "SELECT id FROM scores WHERE userid = %(userid)s AND beatmap_md5 = %(md5)s AND play_mode = %(mode)s AND completed = 3"

        # Mods
        if self.mods > -1:
            mods = "AND mods = %(mods)s"

        # Friends ranking
        if self.friends:
            friends = "AND (scores.userid IN (SELECT user2 FROM users_relationships WHERE user1 = %(userid)s) OR scores.userid = %(userid)s)"

        # Sort and limit at the end
        order = "ORDER BY score DESC"
        limit = "LIMIT 1"

        # Build query, get params and run query
        id_ = glob.db.fetch(self.buildQuery(locals()), {"userid": self.userID, "md5": self.beatmap.fileMD5, "mode": self.gameMode, "mods": self.mods})
        return id_["id"] if id_ else None

    def setScores(self) -> None:
        """
        Set scores list
        """

        # Reset score list
        self.scores = []
        self.scores.append(-1)

        # Make sure the beatmap is uploaded
        if self.beatmap.rankedStatus in [rankedStatuses.UNKNOWN, rankedStatuses.NEED_UPDATE, rankedStatuses.NOT_SUBMITTED]:
            return

        # Check if unrank_leaderboard is enabled
        if self.beatmap.rankedStatus == rankedStatuses.PENDING and generalUtils.stringToBool(glob.conf.config["extra"]["unrank_leaderboard"]) == False:
            return

        # Query parts
        cdef str select = ""
        cdef str joins = ""
        cdef str country = ""
        cdef str mods = ""
        cdef str friends = ""
        cdef str order = ""
        cdef str limit = ""

        # Find personal best score
        personalBestScoreID = self.getPersonalBestID()

        # Output our personal best if found
        if personalBestScoreID is not None:
            s = score.score(personalBestScoreID)
            self.scores[0] = s
        else:
            # No personal best
            self.scores[0] = -1

        # Get top 50 scores
        select = "SELECT scores.id, scores.userid, scores.score, scores.max_combo, scores.play_mode, scores.50_count, scores.100_count, scores.300_count, scores.misses_count, scores.katus_count, scores.gekis_count, scores.full_combo, scores.mods, scores.time, scores.beatmap_md5, scores.completed, scores.pp"
        joins = "FROM scores STRAIGHT_JOIN users ON scores.userid = users.id STRAIGHT_JOIN users_stats ON users.id = users_stats.id WHERE scores.beatmap_md5 = %(beatmap_md5)s AND scores.play_mode = %(play_mode)s AND scores.completed = 3 AND (users.privileges & 1 > 0 OR users.id = %(userid)s)"

        # Country ranking
        if self.country:
            country = "AND users_stats.country = (SELECT country FROM users_stats WHERE id = %(userid)s LIMIT 1)"
        else:
            country = ""

        # Mods ranking (ignore auto, since we use it for pp sorting)
        if self.mods > -1:
            mods = "AND scores.mods = %(mods)s"
        else:
            mods = ""

        # Friends ranking
        if self.friends:
            friends = "AND (scores.userid IN (SELECT user2 FROM users_relationships WHERE user1 = %(userid)s) OR scores.userid = %(userid)s)"
        else:
            friends = ""

        order = "ORDER BY score DESC"

        # Premium members can see up to 75 scores on leaderboards
        if userUtils.getPrivileges(self.userID) & privileges.USER_PREMIUM:
            limit = "LIMIT 75"
        else:
            limit = "LIMIT 50"

        # Build query, get params and run query
        topScores = glob.db.fetchAll(self.buildQuery(locals()), {"beatmap_md5": self.beatmap.fileMD5, "play_mode": self.gameMode, "userid": self.userID, "mods": self.mods})

        # Set data for all scores
        cdef int c = 1
        cdef dict topScore
        if topScores is not None:
            for topScore in topScores:
                # Create score object
                s = score.score(topScore["id"], setData=False)

                # Set data and rank from topScores's row
                s.setDataFromDict(topScore)
                s.rank = c

                # Check if this top 50 score is our personal best
                if s.playerName == self.username:
                    self.personalBestRank = c

                # Add this score to scores list and increment rank
                self.scores.append(s)
                c += 1

        '''# If we have more than 50 scores, run query to get scores count
        if c >= 50:
            # Count all scores on this map
            select = "SELECT COUNT(*) AS count"
            limit = "LIMIT 1"
            # Build query, get params and run query
            query = self.buildQuery(locals())
            count = glob.db.fetch(query, params)
            if count == None:
                self.totalScores = 0
            else:
                self.totalScores = count["count"]
        else:
            self.totalScores = c-1'''

        # If personal best score was not in top 50, try to get it from cache
        if personalBestScoreID is not None and self.personalBestRank < 1:
            self.personalBestRank = glob.personalBestCache.get(self.userID, self.beatmap.fileMD5, self.country, self.friends, self.mods)

        # It's not even in cache, get it from db
        if personalBestScoreID is not None and self.personalBestRank < 1:
            self.setPersonalBestRank()

        # Cache our personal best rank so we can eventually use it later as
        # before personal best rank" in submit modular when building ranking panel
        if self.personalBestRank >= 1:
            glob.personalBestCache.set(self.userID, self.personalBestRank, self.beatmap.fileMD5)
        return

    def setPersonalBestRank(self) -> None:
        """
        Set personal best rank ONLY
        Ikr, that query is HUGE but xd
        """

        # Before running the HUGE query, make sure we have a score on that map
        query: List[str] = "SELECT id FROM scores WHERE beatmap_md5 = %(md5)s AND userid = %(userid)s AND play_mode = %(mode)s AND completed = 3"
        # Mods
        if self.mods > -1:
            query += " AND scores.mods = %(mods)s"
        # Friends ranking
        if self.friends:
            query += " AND (scores.userid IN (SELECT user2 FROM users_relationships WHERE user1 = %(userid)s) OR scores.userid = %(userid)s)"
        # Sort and limit at the end
        query += " LIMIT 1"
        hasScore = glob.db.fetch(query, {"md5": self.beatmap.fileMD5, "userid": self.userID, "mode": self.gameMode, "mods": self.mods})
        if hasScore is None:
            return

        del query

        # We have a score, run the huge query
        # Base query
        query: List[str] = [
            """
            SELECT COUNT(*) AS rank
            FROM scores
            STRAIGHT_JOIN users ON scores.userid = users.id
            STRAIGHT_JOIN users_stats ON users.id = users_stats.id
            WHERE scores.score >= (
                SELECT score
                FROM scores
                WHERE beatmap_md5 = %(md5)s
                    AND play_mode = %(mode)s
                    AND completed = 3
                    AND userid = %(userid)s
                LIMIT 1
            )
                AND scores.beatmap_md5 = %(md5)s
                AND scores.play_mode = %(mode)s
                AND scores.completed = 3
                AND users.privileges & 1 > 0"""
        ]

        # Country
        if self.country:
            query.append("AND users_stats.country = (SELECT country FROM users_stats WHERE id = %(userid)s LIMIT 1)")

        # Mods
        if self.mods > -1:
            query.append("AND scores.mods = %(mods)s")

        # Friends
        if self.friends:
            query.append("AND (scores.userid IN (SELECT user2 FROM users_relationships WHERE user1 = %(userid)s) OR scores.userid = %(userid)s)")

        # Sort and limit at the end
        query.append("ORDER BY score DESC LIMIT 1;")
        result = glob.db.fetch(' '.join(query), {"md5": self.beatmap.fileMD5, "userid": self.userID, "mode": self.gameMode, "mods": self.mods})
        if result is not None: self.personalBestRank = result["rank"]
        return

    def getScoresData(self) -> str:
        """
        Return scores data for getscores
        return -- score data in getscores format
        """

        data: List[str] = ['']

        # Output personal best
        if self.scores[0] == -1:
            # We don't have a personal best score
            data.append('\n')
        else:
            # Set personal best score rank
            self.setPersonalBestRank()	# sets self.personalBestRank with the huge query
            self.scores[0].rank = self.personalBestRank
            data.append(self.scores[0].getData(pp=self.mods > -1))

        # Output top 50 scores
        for i in self.scores[1:]:
            data.append(i.getData(pp=self.mods > -1))

        return ''.join(data)
