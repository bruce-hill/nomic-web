{
  player="spill",
  recorded={},
  request={
    type="join",
  },
  said="spill joined the game. It's spill's turn to propose.",
}
--
{
  player="alice",
  recorded={},
  request={
    type="join",
  },
  said="alice joined the game. It's spill's turn to propose.",
}
--
{
  player="alice",
  recorded={},
  request={
    message="Hello",
    type="message",
  },
  said="alice says: Hello",
}
--
{
  player="spill",
  recorded={
    [1]=false,
  },
  request={
    code="(end my turn) means (next turn)",
    type="proposal",
  },
  said="Proposal 1, by spill:\
    (end my turn) means (next turn)",
}
--
{
  player="alice",
  recorded={},
  request={
    proposal=1,
    type="vote",
    vote="yes",
  },
  said="alice voted yes on proposal 1.",
}
--
{
  player="spill",
  recorded={},
  request={
    proposal=1,
    type="vote",
    vote="yes",
  },
  said="spill voted yes on proposal 1.\
Proposal 1 passes.\
spill gets 3 points.\
Scores: spill 3, alice 0\
It's alice's turn to propose.",
}
--
{
  player="alice",
  recorded={
    [1]=false,
  },
  request={
    code="public:\
    (end my turn) means (next turn)",
    type="proposal",
  },
  said="Proposal 2, by alice:\
    public:\
        (end my turn) means (next turn)",
}
--
{
  player="alice",
  recorded={},
  request={
    proposal=1,
    type="vote",
    vote="yes",
  },
}
--
{
  player="spill",
  recorded={},
  request={
    proposal=1,
    type="vote",
    vote="yes",
  },
}
--
{
  player="spill",
  recorded={},
  request={
    proposal=1,
    type="vote",
    vote="yes",
  },
}
--
{
  player="spill",
  recorded={},
  request={
    proposal=2,
    type="vote",
    vote="yes",
  },
  said="spill voted yes on proposal 2.",
}
--
{
  player="alice",
  recorded={},
  request={
    proposal=2,
    type="vote",
    vote="yes",
  },
  said="alice voted yes on proposal 2.\
Proposal 2 passes.\
alice gets 3 points.\
Scores: spill 3, alice 3\
It's spill's turn to propose.",
}
--
{
  player="alice",
  recorded={},
  request={
    code="pass",
    type="proposal",
  },
  said="alice can't propose now, since it's spill's turn.",
}
--
