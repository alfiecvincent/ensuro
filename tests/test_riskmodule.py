"""Unitary tests for eToken contract"""

from functools import partial
from collections import namedtuple
import pytest
from ethproto.contracts import RevertError, Contract, ERC20Token, ContractProxyField
from ethproto.wrappers import get_provider
from prototype import ensuro
from ethproto.wadray import _W, _R, Wad
from prototype import wrappers
from prototype.utils import WEEK, DAY

TEnv = namedtuple("TEnv", "time_control currency rm_class pool_config kind")


@pytest.fixture(params=["ethereum", "prototype"])
def tenv(request):
    if request.param == "prototype":
        currency = ERC20Token(owner="owner", name="TEST", symbol="TEST", initial_supply=_W(1000))
        pool_config = ensuro.PolicyPoolConfig()

        class PolicyPoolMock(Contract):
            currency = ContractProxyField()
            config = pool_config

            def new_policy(self, policy, customer, internal_id):
                return policy.risk_module.make_policy_id(internal_id)

            def resolve_policy(self, policy_id, customer_won):
                pass

        return TEnv(
            currency=currency,
            time_control=ensuro.time_control,
            pool_config=pool_config,
            kind="prototype",
            rm_class=partial(ensuro.TrustfulRiskModule, policy_pool=PolicyPoolMock(currency=currency))
        )
    elif request.param == "ethereum":
        PolicyPoolMock = get_provider().get_contract_factory("PolicyPoolMock")

        currency = wrappers.TestCurrency(owner="owner", name="TEST", symbol="TEST", initial_supply=_W(1000))
        config = wrappers.PolicyPoolConfig(owner="owner")

        pool = PolicyPoolMock.deploy(currency.contract, config.contract, {"from": currency.owner})

        return TEnv(
            currency=currency,
            time_control=get_provider().time_control,
            pool_config=config,
            kind="ethereum",
            rm_class=partial(wrappers.TrustfulRiskModule,
                             policy_pool=wrappers.PolicyPool.connect(pool, currency.owner))
        )


def test_getset_rm_parameters(tenv):
    rm = tenv.rm_class(
        name="Roulette", scr_percentage=_R(1), ensuro_fee=_R("0.03"),
        scr_interest_rate=_R("0.02"),
        max_scr_per_policy=_W(1000), scr_limit=_W(1000000),
        wallet="CASINO"
    )
    assert rm.name == "Roulette"
    assert rm.scr_percentage == _R(1)
    rm.ensuro_fee.assert_equal(_R(3/100))
    rm.scr_interest_rate.assert_equal(_R(2/100))
    assert rm.max_scr_per_policy == _W(1000)
    assert rm.scr_limit == _W(1000000)
    assert rm.wallet == "CASINO"

    rm.grant_role("RM_PROVIDER_ROLE", "CASINO")  # Grant the role to the casino owner
    tenv.pool_config.grant_role("LEVEL2_ROLE", "L2_USER")  # Grant the role to the casino owner

    users = ("CASINO", "L2_USER", "JOHNDOE")

    test_attributes = [
        ("scr_percentage", "L2_USER", _R(0.8)),
        ("ensuro_fee", "L2_USER", _R(4/100)),
        ("scr_interest_rate", "L2_USER", _R(3/100)),
        ("max_scr_per_policy", "L2_USER", _W(2000)),
        ("scr_limit", "L2_USER", _W(10000000)),
        ("wallet", "CASINO", "CASINO_POCKET"),
    ]

    for attr_name, authorized_user, new_value in test_attributes:
        non_auth_users = [u for u in users if u != authorized_user]
        old_value = getattr(rm, attr_name)
        assert old_value != new_value
        for user in non_auth_users:
            with pytest.raises(RevertError, match="AccessControl"), rm.as_(user):
                setattr(rm, attr_name, new_value)

        with rm.as_(authorized_user):
            setattr(rm, attr_name, new_value)

        assert getattr(rm, attr_name) == new_value

    if tenv.kind == "ethereum":
        with rm.as_("CASINO"), pytest.raises(RevertError):
            rm.wallet = None


def test_getset_rm_parameters_tweaks(tenv):
    if tenv.kind != "ethereum":
        return
    rm = tenv.rm_class(
        name="Roulette", scr_percentage=_R(1), ensuro_fee=_R("0.03"),
        scr_interest_rate=_R("0.02"),
        max_scr_per_policy=_W(1000), scr_limit=_W(1e6),  # 1m
        wallet="CASINO"
    )
    tenv.pool_config.grant_role("LEVEL1_ROLE", "L1_USER")
    tenv.pool_config.grant_role("LEVEL2_ROLE", "L2_USER")
    tenv.pool_config.grant_role("LEVEL3_ROLE", "L3_USER")

    # Validate scr_percentage <= 1 in any case
    with rm.as_("L2_USER"), pytest.raises(RevertError, match="Validation: scrPercentage must be <=1"):
        rm.scr_percentage = _R(1.1)
    with rm.as_("L3_USER"), pytest.raises(RevertError, match="Validation: scrPercentage must be <=1"):
        rm.scr_percentage = _R("1.02")
    with rm.as_("L3_USER"), pytest.raises(RevertError, match="scrPercentage tweaks only up to 10%"):
        rm.scr_percentage = _R(0.7)

    # Verifies hard-coded validations
    test_validations = [
        ("scr_percentage", _R(1.01)),  # <= 1
        ("moc", _R("0.4")),  # [0.5, 2]
        ("moc", _R("2.1")),  # [0.5, 2]
        ("ensuro_fee", _R("1.01")),  # <= 1
        ("scr_interest_rate", _R("1.01")),  # <= 1
    ]

    for attr_name, attr_value in test_validations:
        with rm.as_("L2_USER"), pytest.raises(RevertError, match="Validation: "):
            setattr(rm, attr_name, attr_value)

    # Verifies exceeded tweaks
    test_exceeded_tweaks = [
        ("scr_percentage", _R("0.88")),  # 10% allowed - previous 100
        ("moc", _R("0.88")),  # 10% allowed - previous 1
        ("scr_interest_rate", _R("0.04")),  # 30% allowed
        ("ensuro_fee", _R("0.05")),  # 30% allowed
        ("scr_limit", _W(2e6)),  # 10% allowed - previous 1e6
        ("max_scr_per_policy", _W(1400)),  # 30% allowed
    ]

    for attr_name, attr_value in test_exceeded_tweaks:
        with rm.as_("L3_USER"), pytest.raises(RevertError, match="Tweak exceeded: "):
            setattr(rm, attr_name, attr_value)

    rm.grant_role("RM_PROVIDER_ROLE", "CASINO")  # Grant the role to the casino owner

    assert rm.moc == _R("1")

    # Verifies OK tweaks
    test_ok_tweaks = [
        ("scr_percentage", _R("0.91")),  # 10% allowed - previous 100
        ("moc", _R("1.05")),  # 10% allowed - previous 1
        ("scr_interest_rate", _R("0.025")),  # 30% allowed - previous 2%
        ("ensuro_fee", _R("0.025")),  # 30% allowed - previous 3%
        ("scr_limit", _W(1.05e6)),  # 10% allowed - previous 1.05e6
        ("max_scr_per_policy", _W(1299)),  # 30% allowed - previous 1000
    ]

    for attr_name, attr_value in test_ok_tweaks:
        with rm.as_("L3_USER"):
            setattr(rm, attr_name, attr_value)
        assert getattr(rm, attr_name) == attr_value

    # Verifies L2_USER changes
    test_ok_l2_changes = [
        ("scr_percentage", _R("0.1")),
        ("moc", _R("0.8")),
        ("scr_interest_rate", _R("0.01")),
        ("ensuro_fee", _R("0.01")),
        ("scr_limit", _W(3e6)),
        ("max_scr_per_policy", _W(500)),
    ]

    for attr_name, attr_value in test_ok_l2_changes:
        with rm.as_("L2_USER"):
            setattr(rm, attr_name, attr_value)
        assert getattr(rm, attr_name) == attr_value

    tenv.time_control.fast_forward(WEEK)  # To avoid repeated tweaks

    # Set total liquidity
    rm.policy_pool.contract.setTotalETokenSupply(_W(1e7))
    Wad(rm.policy_pool.contract.totalETokenSupply()).assert_equal(_W(1e7))

    # Increases require LEVEL1_ROLE because more than 10% of total liquidity
    with rm.as_("L2_USER"), pytest.raises(RevertError, match="requires LEVEL1_ROLE"):
        rm.scr_limit = _W(4e6)
    with rm.as_("L3_USER"), pytest.raises(RevertError, match="requires LEVEL1_ROLE"):
        rm.scr_limit = _W(3.1e6)

    # Decreases are OK
    with rm.as_("L3_USER"):
        rm.scr_limit = _W(2.9e6)
        assert rm.scr_limit == _W(2.9e6)
    with rm.as_("L2_USER"):
        rm.scr_limit = _W(2e6)
        assert rm.scr_limit == _W(2e6)

    # L1_USER can increase over 10% liquidity
    with rm.as_("L1_USER"):
        rm.scr_limit = _W(4e6)
        assert rm.scr_limit == _W(4e6)


def test_avoid_repeated_tweaks(tenv):
    if tenv.kind != "ethereum":
        return
    rm = tenv.rm_class(
        name="Roulette", scr_percentage=_R(1), ensuro_fee=_R("0.03"),
        scr_interest_rate=_R("0.02"),
        max_scr_per_policy=_W(1000), scr_limit=_W(1e6),  # 1m
        wallet="CASINO"
    )
    tenv.pool_config.grant_role("LEVEL3_ROLE", "L3_USER")

    with rm.as_("L3_USER"):
        rm.scr_percentage = _R("0.95")
        assert rm.scr_percentage == _R("0.95")
        rm.scr_interest_rate = _R("0.021")
        assert rm.scr_interest_rate == _R("0.021")

    with rm.as_("L3_USER"), pytest.raises(RevertError, match="You already tweaked this parameter recently"):
        rm.scr_percentage = _R("0.93")

    with rm.as_("L3_USER"), pytest.raises(RevertError, match="You already tweaked this parameter recently"):
        rm.scr_interest_rate = _R("0.022")

    tenv.time_control.fast_forward(2 * DAY)

    with rm.as_("L3_USER"):
        rm.scr_percentage = _R("0.96")
        assert rm.scr_percentage == _R("0.96")
        rm.scr_interest_rate = _R("0.022")
        assert rm.scr_interest_rate == _R("0.022")


def test_new_policy(tenv):
    rm = tenv.rm_class(
        name="Roulette", scr_percentage=_R(1), ensuro_fee=_R("0.02"),
        scr_interest_rate=_R("0.01"),
        max_scr_per_policy=_W(1000), scr_limit=_W(1000000),
        wallet="CASINO"
    )
    assert rm.name == "Roulette"
    tenv.currency.transfer(tenv.currency.owner, "CUST1", _W(1))
    tenv.currency.approve("CUST1", rm.policy_pool, _W(1))
    assert tenv.currency.allowance("CUST1", rm.policy_pool) == _W(1)
    expiration = tenv.time_control.now + WEEK

    with rm.as_("JOHN_DOE"), pytest.raises(RevertError, match="is missing role"):
        policy = rm.new_policy(_W(36), _W(1), _R(1/37), expiration, "CUST1", 123)

    rm.grant_role("PRICER_ROLE", "JOHN_SELLER")
    with rm.as_("JOHN_SELLER"):
        policy = rm.new_policy(_W(36), _W(1), _R(1/37), expiration, "CUST1", 123)

    policy.premium.assert_equal(_W(1))
    policy.payout.assert_equal(_W(36))
    policy.loss_prob.assert_equal(_R(1/37))
    policy.pure_premium.assert_equal(_W(36 * 1/37))
    policy.scr.assert_equal(_W(36) - policy.pure_premium)
    assert policy.id == rm.make_policy_id(123)
    assert policy.expiration == expiration
    assert (tenv.time_control.now - policy.start) < 60  # Must be now, giving 60 seconds tolerance
    policy.premium_for_lps.assert_equal(policy.scr * _W("0.01") * _W(7/365))
    policy.premium_for_ensuro.assert_equal((policy.pure_premium + policy.premium_for_lps) * _W("0.02"))
    policy.premium_for_rm.assert_equal(
        _W(1) - policy.pure_premium - policy.premium_for_lps - policy.premium_for_ensuro
    )
    policy.interest_rate.assert_equal(_R("0.01"))

    with rm.as_("JOHN_DOE"), pytest.raises(RevertError, match="is missing role"):
        rm.resolve_policy(policy.id, True)

    rm.grant_role("RESOLVER_ROLE", "JOE_THE_ORACLE")

    with rm.as_("JOE_THE_ORACLE"):
        rm.resolve_policy(policy.id, True)


def test_moc(tenv):
    rm = tenv.rm_class(
        name="Roulette", scr_percentage=_R(1), ensuro_fee=_R("0.01"),
        scr_interest_rate=_R(0),
        max_scr_per_policy=_W(1000), scr_limit=_W(1000000),
        wallet="CASINO"
    )
    tenv.currency.transfer(tenv.currency.owner, "CUST1", _W(1))
    tenv.currency.approve("CUST1", rm.policy_pool, _W(1))
    expiration = tenv.time_control.now + WEEK

    rm.grant_role("PRICER_ROLE", "JOHN_SELLER")
    with rm.as_("JOHN_SELLER"):
        policy = rm.new_policy(_W(36), _W(1), _R(1/37), expiration, "CUST1", 111)

    policy.premium.assert_equal(_W(1))
    policy.loss_prob.assert_equal(_R(1/37))
    policy.pure_premium.assert_equal(_W(36 * 1/37))
    policy.premium_for_ensuro.assert_equal(_W(36 * 1/37 * 0.01))
    assert policy.id == rm.make_policy_id(111)

    with pytest.raises(RevertError, match="missing role"):
        rm.moc = _R("1.01")

    tenv.pool_config.grant_role("LEVEL2_ROLE", "DAO")
    with rm.as_("DAO"):
        rm.moc = _R("1.01")

    assert rm.moc == _R("1.01")

    with rm.as_("JOHN_SELLER"):
        policy2 = rm.new_policy(_W(36), _W(1), _R(1/37), expiration, "CUST1", 112)

    policy2.premium.assert_equal(_W(1))
    assert policy2.id == rm.make_policy_id(112)
    policy2.loss_prob.assert_equal(_R(1/37))
    policy2.pure_premium.assert_equal(_W(36 * 1/37) * _W("1.01"))
    policy2.premium_for_ensuro.assert_equal(_W(36 * 1/37 * 0.01) * _W("1.01"))


def test_minimum_premium(tenv):
    rm = tenv.rm_class(
        name="Roulette", scr_percentage=_R("0.2"), ensuro_fee=_R("0.01"),
        scr_interest_rate=_R("0.10"),
        max_scr_per_policy=_W(1000), scr_limit=_W(1000000),
        wallet="CASINO"
    )
    tenv.pool_config.grant_role("LEVEL2_ROLE", "DAO")
    with rm.as_("DAO"):
        rm.moc = _R("1.3")

    expiration = tenv.time_control.now + WEEK
    pure_premium = _W(36/37) * _W("1.3")
    scr = _W(36) * _W("0.2") - pure_premium
    rm.get_minimum_premium(_W(36), _R(1/37), expiration).assert_equal(
        (pure_premium + scr * _W(7/365) * _W("0.10")) * _W("1.01")
    )
    minimum_premium = rm.get_minimum_premium(_W(36), _R(1/37), expiration)

    tenv.currency.transfer(tenv.currency.owner, "CUST1", _W(2))
    tenv.currency.approve("CUST1", rm.policy_pool, _W(2))

    rm.grant_role("PRICER_ROLE", "JOHN_SELLER")
    with rm.as_("JOHN_SELLER"), pytest.raises(RevertError, match="less than minimum"):
        policy = rm.new_policy(_W(36), _W("1.28"), _R(1/37), expiration, "CUST1", 222)

    with rm.as_("JOHN_SELLER"):
        policy = rm.new_policy(
            _W(36), rm.get_minimum_premium(_W(36), _R(1/37), expiration),
            _R(1/37), expiration, "CUST1", 222
        )

    policy.premium.assert_equal(minimum_premium, decimals=3)
    policy.loss_prob.assert_equal(_R(1/37))
    policy.pure_premium.assert_equal(_W(36 * 1/37 * 1.3))
    policy.premium_for_ensuro.assert_equal((policy.pure_premium + policy.premium_for_lps) * _W("0.01"))
