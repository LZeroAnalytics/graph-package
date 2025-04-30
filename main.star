postgres = import_module("github.com/tiljrd/postgres-package/main.star")

# The min/max CPU/memory that postgres can use
POSTGRES_MIN_CPU = 10
POSTGRES_MAX_CPU = 1000
POSTGRES_MIN_MEMORY = 32
POSTGRES_MAX_MEMORY = 1024

def run(plan, args={}):

    rpc_url = args["rpc"]

    postgres_output = postgres.run(
        plan,
        service_name="postgres",
        min_cpu=POSTGRES_MIN_CPU,
        max_cpu=POSTGRES_MAX_CPU,
        min_memory=POSTGRES_MIN_MEMORY,
        max_memory=POSTGRES_MAX_MEMORY,
        extra_env_vars={
            "POSTGRES_INITDB_ARGS": "-E UTF8 --locale=C"
        }
    )

    postgres_user = postgres_output.user
    postgres_password = postgres_output.password
    postgres_hostname = postgres_output.service.hostname
    postgres_database = postgres_output.database

    ipfs_output = plan.add_service(
        name="ipfs",
        config=ServiceConfig(
            image="ipfs/kubo:master-latest",
            ports={
               "rpc": PortSpec(number=5001, transport_protocol="TCP"),
                "p2p": PortSpec(number=4001, transport_protocol="TCP"),
                "gateway": PortSpec(number=8080, transport_protocol="TCP", application_protocol="http")
            }
        )
    )

    ipfs_ip = ipfs_output.ip_address
    ipfs_url = "{}:5001".format(ipfs_ip)

    plan.print(ipfs_output)
    plan.print(ipfs_url)

    graph_output = plan.add_service(
        name="graph-node",
        config=ServiceConfig(
            image="graphprotocol/graph-node",
            ports={
                "http": PortSpec(number=8000, transport_protocol="TCP", application_protocol="http", wait=None),
                "ws": PortSpec(number=8001, transport_protocol="TCP", wait=None),
                "rpc": PortSpec(number=8020, transport_protocol="TCP", wait=None),
                "api": PortSpec(number=8030, transport_protocol="TCP", wait=None),
                "prometheus": PortSpec(number=8040, transport_protocol="TCP", wait=None)
            },
            env_vars = {
                "postgres_host": postgres_hostname,
                "postgres_user": postgres_user,
                "postgres_pass": postgres_password,
                "postgres_db": postgres_database,
                "ipfs": ipfs_url,
                "ethereum": "bloctopus:{}".format(rpc_url)
            }
        )
    )

    plan.print(graph_output)