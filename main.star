# The min/max CPU/memory that postgres can use
POSTGRES_MIN_CPU = 10
POSTGRES_MAX_CPU = 1000
POSTGRES_MIN_MEMORY = 32
POSTGRES_MAX_MEMORY = 1024

def run(plan, ethereum_args=None, network_type="bloctopus", rpc_url=None, env="main", prefix=""):

    plan.print("Running graph package on branch {}".format(env))

    postgres = import_module("github.com/tiljrd/postgres-package@{}/main.star".format(env))
    ethereum = import_module("github.com/LZeroAnalytics/ethereum-package@{}/main.star".format(env))

    if not rpc_url:
        plan.print("Running the ethereum package")
        result = ethereum.run(plan, ethereum_args)
        first = result.all_participants[0]
        rpc_url = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num)

    postgres_output = postgres.run(
        plan,
        service_name="{}postgres".format(prefix),
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
        name="{}ipfs".format(prefix),
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
        name="{}graph-node".format(prefix),
        config=ServiceConfig(
            image="graphprotocol/graph-node",
            ports={
    # Build environment variables
    env_vars = {
        "postgres_host": postgres_hostname,
        "postgres_user": postgres_user,
        "postgres_pass": postgres_password,
        "postgres_db": postgres_database,
        "ipfs": ipfs_url,
        "ethereum": "{}:{}".format(network_type, rpc_url)
    }
    
    # Add substreams support if endpoint is provided
    if ethereum_args and "substreams_endpoint" in ethereum_args:
        substreams_endpoint = ethereum_args["substreams_endpoint"]
        env_vars["GRAPH_NODE_CONFIG"] = "/etc/graph-node/config.toml"
        # Create a basic config that includes substreams endpoint
        config_content = """
[chains.{}]
shard = "primary"
provider = [
  {{ label = "ethereum-rpc", url = "{}", features = ["archive", "traces"] }},
  {{ label = "substreams", url = "{}", features = ["substreams"] }}
]
""".format(network_type, rpc_url, substreams_endpoint)
        
        # Store config as a file artifact
        config_artifact = plan.render_templates(
            config={{
                "config.toml": struct(
                    template=config_content,
                    data={{}}
                )
            }},
            name="graph-node-config"
        )
        
        # Mount the config file
        files = {{
            "/etc/graph-node/": config_artifact
        }}
    else:
        files = {{}}
        )
    )

    graph_services = struct(
        postgres = postgres_output,
        ipfs = ipfs_output,
        graph = graph_output
    )

    return graph_services
