#!/usr/bin/python3
# -*- coding: UTF-8 -*-
from objects.rxscore import score
from objects.beatmap import beatmap
from common.db import dbConnector
from objects import glob
from helpers import config
import sys

if __name__ == "__main__":

    glob.conf = config.config("config.ini")

    glob.db = dbConnector.db(glob.conf.config["db"]["host"], glob.conf.config["db"]["username"], glob.conf.config["db"]["password"], glob.conf.config["db"]["database"], int(
                    glob.conf.config["db"]["workers"]))

    print("成绩序号\t玩家名字\t铺面ID\tRANK状态\t原分数\t原pp\t新分数\t新pp")

    for score_id in range(int(sys.argv[1]), int(sys.argv[2])):
        s = score(scoreID=score_id)
        if s.score != 0 and s.completed in [3, 2]:
            b = beatmap()
            if b.setDataFromDB(s.fileMd5):
                print(f"{s.scoreID}\t{s.playerName}\t{b.beatmapID}\t{b.rankedStatus}\t{s.score}\t{s.pp}\t", end="")
                s.passed = True
                s.calculatePP(b)
                glob.db.execute("UPDATE scores_relax SET score = %s, pp = %s WHERE id = %s", [s.score, s.pp, score_id])
                print(f"{s.score}\t{s.pp}")
