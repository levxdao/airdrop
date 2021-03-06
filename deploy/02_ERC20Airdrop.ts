export default async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("ERC20Airdrops", {
        from: deployer,
        log: true,
    });
};
